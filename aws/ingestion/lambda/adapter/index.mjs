/**
 * CloudFront logs -> Obsero.
 *
 * Firehose cannot POST to Obsero directly: it wraps records in its own batch
 * envelope, sends its key in X-Amz-Firehose-Access-Key, and demands a specific
 * JSON ack back. This Lambda sits behind a Function URL and translates.
 *
 * Read it in three parts:
 *
 *   1. THE CONTRACT      build the payload and POST it   <- keep this
 *   2. CLOUDFRONT         log line -> event               <- rewrite for your source
 *   3. FIREHOSE PLUMBING  unwrap the batch, ack it        <- rewrite for your source
 *
 * Only part 1 is Obsero's business. See ../../../../README.md and obsero.mjs
 * at the repo root for the contract on its own.
 */

// ===========================================================================
// 1. THE CONTRACT
// ===========================================================================

const INGEST_URL = process.env.OBSERO_INGEST_URL;
const SITE_TOKEN = process.env.OBSERO_SITE_TOKEN;

/**
 * One JSON POST per HTTP request:
 *
 *   { path, method, statusCode, headers }
 *
 * `path` carries no query string -- otherwise every distinct URL becomes its
 * own page in the analytics. `headers` is what classification runs on.
 */
export function toPayload({ domain: _domain, query: _query, ...payload }) {
  return payload;
}

async function forward(event) {
  const headers = {
    "content-type": "application/json",
    "x-obsero-domain": event.domain,
  };
  if (SITE_TOKEN) headers["x-obsero-key"] = SITE_TOKEN;

  try {
    const res = await fetch(INGEST_URL, {
      method: "POST",
      headers,
      body: JSON.stringify(toPayload(event)),
      signal: AbortSignal.timeout(10_000),
    });
    if (!res.ok) {
      console.warn("forward_non_ok", { status: res.status });
      return false;
    }
    return true;
  } catch (err) {
    console.warn("forward_failed", { message: String(err?.message ?? err) });
    return false;
  }
}

/** POST every event with a bounded number of sockets in flight. */
async function forwardAll(events) {
  let cursor = 0;
  let failures = 0;

  const worker = async () => {
    while (cursor < events.length) {
      if (!(await forward(events[cursor++]))) failures++;
    }
  };

  await Promise.all(
    Array.from({ length: Math.min(CONCURRENCY, events.length) }, worker),
  );
  return failures;
}

// ===========================================================================
// 2. CLOUDFRONT: one log line -> one event
// ===========================================================================

const EXCLUDED_HEADERS = envList(process.env.EXCLUDED_HEADERS, [
  "authorization",
  "cookie",
  "set-cookie",
]);

const SKIPPED_PATHS = new Set(
  envList(process.env.SKIPPED_PATHS, ["/health", "/favicon.ico"]),
);

const FIELDS = (process.env.CLOUDFRONT_LOG_FIELDS ?? "").split(",");

// "standard-json" = CloudFront standard logging v2 (named JSON fields).
// "realtime-tsv"  = CloudFront real-time logs (positional, tab separated).
const LOG_FORMAT = process.env.LOG_FORMAT ?? "realtime-tsv";

/** Turn one CloudFront log record into an Obsero event, or null to skip it. */
export function toObseroEvent(line) {
  return LOG_FORMAT === "standard-json"
    ? fromStandardJson(line)
    : fromRealtimeTsv(line);
}

/**
 * Standard logging v2, delivered as JSON with named fields. CloudFront exposes
 * only a handful of request headers here -- there is no cs-headers -- so the
 * header map is thin by nature, not by omission.
 */
function fromStandardJson(line) {
  let row;
  try {
    row = JSON.parse(line);
  } catch {
    return null;
  }
  if (!row || typeof row !== "object") return null;

  const path = clean(pick(row, "cs-uri-stem")).split("?")[0] || "/";
  if (SKIPPED_PATHS.has(path.toLowerCase())) return null;

  const domain = clean(pick(row, "x-host-header", "cs(Host)", "cs-host"));
  const headers = {};
  addHeader(headers, "host", domain);
  addHeader(headers, "user-agent", pick(row, "cs(User-Agent)", "cs-user-agent"));
  addHeader(headers, "referer", pick(row, "cs(Referer)", "cs-referer"));
  addHeader(headers, "x-forwarded-for", pick(row, "x-forwarded-for"));

  return {
    path,
    method: (clean(pick(row, "cs-method")) || "GET").toUpperCase(),
    statusCode: Number(clean(pick(row, "sc-status"))) || 0,
    headers,
    domain,
    query: clean(pick(row, "cs-uri-query")),
  };
}

/**
 * Real-time logs: tab separated, no header row, parsed positionally.
 *
 * CloudFront emits fields in its own canonical order, not the order you asked
 * for, so the module sorts the list and passes it in CLOUDFRONT_LOG_FIELDS.
 */
function fromRealtimeTsv(line) {
  const values = line.split("\t");
  const row = {};
  FIELDS.forEach((field, i) => {
    const value = values[i];
    row[field] = value === undefined || value === "-" ? "" : value;
  });

  // In *real-time* logs cs-uri-stem carries the query string too, unlike
  // standard logs.
  const path = (row["cs-uri-stem"] || "/").split("?")[0] || "/";
  if (SKIPPED_PATHS.has(path.toLowerCase())) return null;

  return {
    path,
    method: (row["cs-method"] || "GET").toUpperCase(),
    statusCode: Number(row["sc-status"]) || 0,
    headers: parseHeaders(row),
    domain: row["x-host-header"] || row["cs-host"] || "",
  };
}

/**
 * cs-headers arrives as percent-encoded "name:value" pairs joined by %0A, e.g.
 *   host:example.com%0Auser-agent:curl/8.5%0Aaccept:*%2F*%0A
 * Split on the encoded separator *before* decoding, so a header value that
 * itself decodes to a newline cannot forge an extra header. Falls back to the
 * individually logged fields so an event is never dropped for want of headers.
 */
export function parseHeaders(row) {
  const headers = {};
  const raw = row["cs-headers"];

  if (raw) {
    for (const entry of raw.split(/%0A/i)) {
      if (!entry) continue;
      const sep = entry.indexOf(":");
      if (sep <= 0) continue;
      const name = safeDecode(entry.slice(0, sep)).trim().toLowerCase();
      const value = safeDecode(entry.slice(sep + 1)).trim();
      if (!name || EXCLUDED_HEADERS.includes(name)) continue;
      headers[name] = value;
    }
  }

  if (Object.keys(headers).length === 0) {
    const fallback = {
      host: row["x-host-header"] || row["cs-host"],
      "user-agent": row["cs-user-agent"],
      referer: row["cs-referer"],
      "x-forwarded-for": row["x-forwarded-for"],
    };
    for (const [name, value] of Object.entries(fallback)) {
      if (value) headers[name] = safeDecode(value);
    }
  }

  return headers;
}

/** First non-empty value among several possible field spellings. */
function pick(row, ...names) {
  for (const name of names) {
    const value = row[name];
    if (value !== undefined && value !== null && value !== "" && value !== "-") {
      return String(value);
    }
  }
  return "";
}

/** CloudFront percent-encodes standard log values. */
function clean(value) {
  return value ? safeDecode(value).trim() : "";
}

function addHeader(headers, name, value) {
  const decoded = clean(value);
  if (decoded && !EXCLUDED_HEADERS.includes(name)) headers[name] = decoded;
}

function safeDecode(value) {
  try {
    return decodeURIComponent(value);
  } catch {
    return value;
  }
}

/** Comma-separated env list, falling back when unset or empty. */
function envList(value, fallback) {
  const parsed = (value ?? "")
    .split(",")
    .map((entry) => entry.trim().toLowerCase())
    .filter(Boolean);
  return parsed.length > 0 ? parsed : fallback;
}

// ===========================================================================
// 3. FIREHOSE PLUMBING: unwrap the batch envelope, return the ack
// ===========================================================================

const FIREHOSE_KEY = process.env.FIREHOSE_ACCESS_KEY;
const CONCURRENCY = Number(process.env.FORWARD_CONCURRENCY ?? 8);

// Opt-in: log every forwarded event and one raw sample per batch. Off by
// default -- it multiplies CloudWatch volume by the request rate.
const DEBUG_EVENTS = process.env.DEBUG_LOG_EVENTS === "true";

export const handler = async (event) => {
  const requestId = header(event, "x-amz-firehose-request-id") ?? "unknown";

  // Function URLs are public, so the shared key is the only gate.
  const presented = header(event, "x-amz-firehose-access-key");
  if (!FIREHOSE_KEY || presented !== FIREHOSE_KEY) {
    return ack(401, requestId, "invalid access key");
  }

  let body;
  try {
    const raw = event.isBase64Encoded
      ? Buffer.from(event.body ?? "", "base64").toString("utf8")
      : (event.body ?? "");
    body = JSON.parse(raw);
  } catch (err) {
    return ack(400, requestId, `malformed body: ${err.message}`);
  }

  const records = Array.isArray(body?.records) ? body.records : [];
  const events = [];

  for (const record of records) {
    const decoded = Buffer.from(record.data ?? "", "base64").toString("utf8");
    // One Firehose record can carry several newline-delimited log lines.
    for (const line of decoded.split("\n")) {
      if (!line.trim()) continue;
      const parsed = toObseroEvent(line);
      if (parsed) events.push(parsed);
    }
  }

  if (DEBUG_EVENTS && records.length > 0) {
    const sample = Buffer.from(records[0].data ?? "", "base64")
      .toString("utf8")
      .split("\n")
      .find((l) => l.trim());
    console.log("raw_sample", JSON.stringify(sample ?? "").slice(0, 1800));
  }

  if (events.length === 0) return ack(200, body?.requestId ?? requestId);

  if (DEBUG_EVENTS) {
    for (const parsed of events) {
      console.log("event", JSON.stringify(toPayload(parsed)));
    }
  }

  const failures = await forwardAll(events);

  if (failures > 0) {
    // Fail the whole batch so Firehose retries, then backs up to S3. Costs
    // duplicates for the records that already landed -- at-least-once.
    console.warn("batch_partial_failure", {
      failed: failures,
      total: events.length,
    });
    return ack(
      500,
      body?.requestId ?? requestId,
      `${failures}/${events.length} events failed to forward`,
    );
  }

  console.log("batch_forwarded", { count: events.length });
  return ack(200, body?.requestId ?? requestId);
};

function header(event, name) {
  const headers = event?.headers ?? {};
  return headers[name] ?? headers[name.toLowerCase()];
}

/** Firehose treats a delivery as failed unless it gets this shape back. */
function ack(statusCode, requestId, errorMessage) {
  return {
    statusCode,
    headers: { "content-type": "application/json" },
    body: JSON.stringify({
      requestId,
      timestamp: Date.now(),
      ...(errorMessage ? { errorMessage } : {}),
    }),
  };
}
