#!/usr/bin/env node
/**
 * The Obsero contract, in one file.
 *
 * Obsero cares about exactly two things:
 *
 *   1. the URL you POST to
 *   2. the JSON body and the two headers that go with it
 *
 * Everything else -- which cloud, which log source, which language, whether
 * you buffer or send per request -- is yours to decide. This file is the
 * reference: copy it, port it, or just read it and write your own.
 *
 * Run it to send one test event and confirm your token works:
 *
 *   node obsero.mjs --token <site-token> --domain acme.com
 *   node obsero.mjs --token <site-token> --domain acme.com --path /pricing
 *   node obsero.mjs --token <site-token> --domain acme.com --url https://analytics.obsero.ai/v1/events
 */

/** Default ingest endpoint. Override per environment. */
export const INGEST_URL = "https://analytics-staging.obsero.ai/v1/events";

/** Never forward these, whatever your log source hands you. */
export const EXCLUDED_HEADERS = ["authorization", "cookie", "set-cookie"];

/**
 * Build one Obsero event from whatever your log source gives you.
 *
 * The four fields below are the whole payload. Extra fields are ignored, so
 * adding your own costs nothing but bytes.
 *
 *   path        request path ONLY -- no query string, no origin.
 *               "/pricing", not "/pricing?ref=x" and not "https://acme.com/pricing".
 *               Sending the query string turns every distinct URL into its own
 *               page in the analytics, which is the single most common mistake.
 *   method      uppercase HTTP verb. "GET".
 *   statusCode  number, not string. 200.
 *   headers     lowercase header names -> values, verbatim.
 *               This is what classification runs on: user-agent, from,
 *               signature-agent/signature-input/signature (Web Bot Auth),
 *               accept, accept-language, sec-ch-ua*, sec-fetch-*.
 *               The more you send, the better the classification.
 */
export function buildEvent({ path, method, statusCode, headers = {} }, options = {}) {
  const excluded = options.excludedHeaders ?? EXCLUDED_HEADERS;
  const clean = {};

  for (const [name, value] of Object.entries(headers)) {
    const key = String(name).trim().toLowerCase();
    const text = value == null ? "" : String(value).trim();
    if (!key || !text || excluded.includes(key)) continue;
    clean[key] = text;
  }

  return {
    path: stripQuery(path),
    method: String(method || "GET").toUpperCase(),
    statusCode: Number(statusCode) || 0,
    headers: clean,
  };
}

/** POST one event. Resolves true on success, false on anything else. */
export async function sendEvent(event, { url = INGEST_URL, token, domain } = {}) {
  const headers = { "content-type": "application/json" };
  // Which site the event belongs to, and the key that proves you own it.
  if (domain) headers["x-obsero-domain"] = domain;
  if (token) headers["x-obsero-key"] = token;

  try {
    const res = await fetch(url, {
      method: "POST",
      headers,
      body: JSON.stringify(event),
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

/**
 * Check an event before you ship a custom adapter. Returns a list of problems,
 * empty when the payload is good. Used by each cloud's `make test`.
 */
export function validateEvent(event) {
  const problems = [];
  const { path, method, statusCode, headers } = event ?? {};

  if (typeof path !== "string" || !path.startsWith("/")) {
    problems.push(`path must be a string starting with "/", got ${JSON.stringify(path)}`);
  } else if (path.includes("?")) {
    problems.push(`path must not carry a query string, got ${JSON.stringify(path)}`);
  }

  if (typeof method !== "string" || method !== method.toUpperCase()) {
    problems.push(`method must be an uppercase string, got ${JSON.stringify(method)}`);
  }

  if (typeof statusCode !== "number" || !Number.isFinite(statusCode)) {
    problems.push(`statusCode must be a number, got ${JSON.stringify(statusCode)}`);
  }

  if (!headers || typeof headers !== "object" || Array.isArray(headers)) {
    problems.push("headers must be an object");
  } else {
    for (const [name, value] of Object.entries(headers)) {
      if (name !== name.toLowerCase()) problems.push(`header name must be lowercase: ${name}`);
      if (typeof value !== "string") problems.push(`header ${name} must be a string`);
      if (EXCLUDED_HEADERS.includes(name)) problems.push(`header ${name} must never be forwarded`);
    }
    if (!headers["user-agent"]) {
      problems.push("headers.user-agent is missing -- classification needs it");
    }
  }

  return problems;
}

/** "/pricing?ref=x" -> "/pricing". Also tolerates an absolute URL. */
function stripQuery(value) {
  const text = String(value ?? "/");
  const path = text.startsWith("http") ? safePathname(text) : text;
  return path.split("?")[0] || "/";
}

function safePathname(text) {
  try {
    return new URL(text).pathname;
  } catch {
    return text;
  }
}

// --- CLI: send one test event ----------------------------------------------

if (import.meta.url === `file://${process.argv[1]}`) {
  const args = Object.fromEntries(
    process.argv.slice(2).flatMap((arg, i, all) =>
      arg.startsWith("--") ? [[arg.slice(2), all[i + 1]?.startsWith("--") ? true : all[i + 1]]] : [],
    ),
  );

  const event = buildEvent({
    path: args.path ?? "/",
    method: "GET",
    statusCode: 200,
    headers: {
      host: args.domain ?? "example.com",
      "user-agent":
        "Mozilla/5.0 AppleWebKit/537.36 (KHTML, like Gecko); compatible; ChatGPT-User/1.0; +https://openai.com/bot",
      accept: "*/*",
      "signature-agent": '"https://chatgpt.com"',
    },
  });

  const problems = validateEvent(event);
  if (problems.length > 0) {
    console.error("invalid event:\n  " + problems.join("\n  "));
    process.exit(1);
  }

  const url = args.url ?? INGEST_URL;
  console.log(`POST ${url}`);
  console.log(JSON.stringify(event, null, 2));

  const ok = await sendEvent(event, { url, token: args.token, domain: args.domain });
  console.log(ok ? "accepted" : "rejected");
  process.exit(ok ? 0 : 1);
}
