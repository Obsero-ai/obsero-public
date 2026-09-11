/**
 * Load balancer request logs -> Obsero.
 *
 * Cloud Logging routes one load-balancer request log entry per Pub/Sub
 * message. This Cloud Run service unpacks the push envelope, turns the entry
 * into one Obsero event, and acks.
 *
 * Read it in three parts:
 *
 *   1. THE CONTRACT      build the payload and POST it   <- keep this
 *   2. CLOUD LOGGING     log entry -> event               <- rewrite for your source
 *   3. PUSH PLUMBING     unwrap the envelope, ack it      <- rewrite for your source
 *
 * Only part 1 is Obsero's business. See ../../../README.md and obsero.mjs at
 * the repo root for the contract on its own.
 *
 * Simpler than the AWS adapter, because Cloud Logging delivers structured
 * JSON: no batch envelope, no positional parsing, no field-order trap. Auth is
 * handled before this code runs -- the push subscription presents an OIDC
 * token and Cloud Run rejects anything without run.invoker, so there is no
 * shared secret to check.
 */
import { createServer } from "node:http";

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

// ===========================================================================
// 2. CLOUD LOGGING: one log entry -> one event
// ===========================================================================

/** Comma-separated env list, falling back when unset or empty. */
function envList(value, fallback) {
  const parsed = (value ?? "")
    .split(",")
    .map((entry) => entry.trim().toLowerCase())
    .filter(Boolean);
  return parsed.length > 0 ? parsed : fallback;
}

const EXCLUDED_HEADERS = envList(process.env.EXCLUDED_HEADERS, [
  "authorization",
  "cookie",
  "set-cookie",
]);

const SKIPPED_PATHS = new Set(
  envList(process.env.SKIPPED_PATHS, ["/health", "/favicon.ico"]),
);

const DEBUG_EVENTS = process.env.DEBUG_LOG_EVENTS === "true";

/**
 * Where the `--logging-http-request-headers` allow-list lands, verified
 * against a live entry:
 *
 *   jsonPayload.loggingHttpRequestHeaders: [
 *     { headerKey: "from", headerValue: "Ym90QG9wZW5haS5jb20=" },
 *     ...
 *   ]
 *
 * An array of pairs rather than a map, and every value is base64-encoded.
 * That encoding is why Web Bot Auth signatures survive intact -- quotes,
 * commas and embedded colons all come back byte-for-byte. A header that was
 * not sent is simply absent; there is no empty-string placeholder.
 */
const HEADER_FIELD = "loggingHttpRequestHeaders";

/** Turn one Cloud Logging entry into an Obsero event, or null to skip it. */
export function toObseroEvent(entry) {
  const request = entry?.httpRequest ?? {};
  const { path, query, host } = splitUrl(request.requestUrl);

  if (SKIPPED_PATHS.has(path.toLowerCase())) return null;

  const headers = collectHeaders(entry);
  const domain = headers.host || host || "";
  if (domain) headers.host = domain;

  return {
    path,
    method: (request.requestMethod || "GET").toUpperCase(),
    statusCode: Number(request.status) || 0,
    headers,
    domain,
    query,
  };
}

/**
 * The allow-listed request headers, plus the three the load balancer reports
 * as first-class httpRequest fields whether or not they were asked for. The
 * allow-list wins on conflict: it is the verbatim header, where userAgent and
 * referer have been through Cloud Logging's own normalisation.
 */
export function collectHeaders(entry) {
  const headers = {};

  const add = (name, value) => {
    const key = String(name).trim().toLowerCase();
    const text = value == null ? "" : String(value).trim();
    if (!key || !text || EXCLUDED_HEADERS.includes(key)) return;
    headers[key] = text;
  };

  const request = entry?.httpRequest ?? {};
  add("user-agent", request.userAgent);
  add("referer", request.referer);
  add("x-forwarded-for", request.remoteIp);

  const logged = resolveHeaderMap(entry);
  for (const [name, value] of Object.entries(logged)) add(name, value);

  return headers;
}

/** The allow-listed headers, decoded. */
function resolveHeaderMap(entry) {
  const logged = entry?.jsonPayload?.[HEADER_FIELD];
  const headers = {};

  if (Array.isArray(logged)) {
    for (const item of logged) {
      if (!item?.headerKey) continue;
      headers[item.headerKey] = decodeHeaderValue(item.headerValue);
    }
    return headers;
  }

  // Tolerated, not expected: a plain map, should the shape ever change. Values
  // are taken verbatim -- only the array form is known to be base64.
  if (logged && typeof logged === "object") {
    for (const [name, value] of Object.entries(logged)) {
      if (typeof value === "string" || typeof value === "number") {
        headers[name] = String(value);
      }
    }
    return headers;
  }

  if (DEBUG_EVENTS) {
    console.log("no_header_map", {
      top: Object.keys(entry ?? {}),
      jsonPayload: Object.keys(entry?.jsonPayload ?? {}),
    });
  }
  return headers;
}

/**
 * Header values arrive base64-encoded. If a decode ever yields a replacement
 * character the value was not base64 after all, so the raw string is kept
 * rather than silently mangled.
 */
export function decodeHeaderValue(value) {
  if (value == null) return "";
  const text = String(value);
  try {
    const decoded = Buffer.from(text, "base64").toString("utf8");
    return decoded.includes("\uFFFD") ? text : decoded;
  } catch {
    return text;
  }
}

/**
 * requestUrl is absolute. The query is split off here, or every distinct query
 * string becomes its own path in the analytics.
 */
export function splitUrl(requestUrl) {
  if (!requestUrl) return { path: "/", query: "", host: "" };

  try {
    const url = new URL(requestUrl);
    return {
      path: url.pathname || "/",
      query: url.search.replace(/^\?/, ""),
      host: url.host,
    };
  } catch {
    const [rawPath = "/", ...rest] = String(requestUrl).split("?");
    return { path: rawPath || "/", query: rest.join("?"), host: "" };
  }
}

// ===========================================================================
// 3. PUSH PLUMBING: unwrap the Pub/Sub envelope, ack it
// ===========================================================================

const PORT = Number(process.env.PORT ?? 8080);

const server = createServer(async (req, res) => {
  if (req.method === "GET") {
    // Cloud Run startup probe.
    res.writeHead(200, { "content-type": "text/plain" });
    return res.end("ok\n");
  }

  let body;
  try {
    body = JSON.parse(await readBody(req));
  } catch (err) {
    console.warn("malformed_body", { message: String(err?.message ?? err) });
    // 400 is terminal: retrying an unparseable push just burns quota until it
    // dead-letters anyway.
    return respond(res, 400);
  }

  let entries;
  try {
    entries = decodeEntries(body);
  } catch (err) {
    console.warn("malformed_message", { message: String(err?.message ?? err) });
    return respond(res, 400);
  }

  if (DEBUG_EVENTS && entries.length > 0) {
    console.log("raw_sample", JSON.stringify(entries[0]).slice(0, 2000));
  }

  const events = entries.map(toObseroEvent).filter(Boolean);
  if (events.length === 0) return respond(res, 204);

  if (DEBUG_EVENTS) {
    for (const event of events) console.log("event", JSON.stringify(toPayload(event)));
  }

  let failures = 0;
  for (const event of events) {
    if (!(await forward(event))) failures++;
  }

  if (failures > 0) {
    // Non-2xx makes Pub/Sub retry with backoff and eventually dead-letter.
    // At-least-once, same as Firehose, except the failed messages stay queued
    // and replayable instead of landing as gzip in a bucket.
    console.warn("push_partial_failure", { failed: failures, total: events.length });
    return respond(res, 500);
  }

  console.log("forwarded", { count: events.length });
  return respond(res, 204);
});

/**
 * A push delivery carries exactly one message, whose data is one log entry.
 * Both are handled as arrays anyway: the sink's batching behaviour is not
 * contractual, and an entry that arrives as a list should not be dropped.
 */
export function decodeEntries(body) {
  const messages = body?.message ? [body.message] : (body?.messages ?? []);
  const entries = [];

  for (const message of messages) {
    if (!message?.data) continue;
    const decoded = JSON.parse(
      Buffer.from(message.data, "base64").toString("utf8"),
    );
    if (Array.isArray(decoded)) entries.push(...decoded);
    else entries.push(decoded);
  }

  return entries;
}

function readBody(req) {
  return new Promise((resolve, reject) => {
    let raw = "";
    req.setEncoding("utf8");
    req.on("data", (chunk) => (raw += chunk));
    req.on("end", () => resolve(raw));
    req.on("error", reject);
  });
}

function respond(res, statusCode) {
  res.writeHead(statusCode);
  res.end();
}

if (process.env.NODE_ENV !== "test") {
  server.listen(PORT, () => console.log(`adapter listening on :${PORT}`));
}
