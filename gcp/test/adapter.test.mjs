/**
 * Runs the real adapter parser over sample Cloud Logging entries and checks
 * the resulting payload against the Obsero contract. No GCP project needed:
 *
 *   make test
 *
 * If you rewrite the adapter for your own log source, change the fixtures and
 * keep the assertions -- they are what Obsero actually requires.
 */
import test from "node:test";
import assert from "node:assert/strict";
import { validateEvent } from "../../obsero.mjs";

// Keeps the adapter from binding a port on import.
process.env.NODE_ENV = "test";

const { toObseroEvent, toPayload, decodeEntries, splitUrl, decodeHeaderValue } =
  await import("../ingestion/adapter/index.mjs");

/** base64, the way the load balancer logs every allow-listed header value. */
const b64 = (value) => Buffer.from(value, "utf8").toString("base64");

/** One load-balancer request log entry, as Cloud Logging delivers it. */
const entry = {
  httpRequest: {
    requestMethod: "GET",
    requestUrl: "https://acme.com/pricing?ref=hn",
    status: 200,
    userAgent: "Mozilla/5.0 (compatible; ChatGPT-User/1.0; +https://openai.com/bot)",
    remoteIp: "203.0.113.7",
  },
  jsonPayload: {
    loggingHttpRequestHeaders: [
      { headerKey: "signature-agent", headerValue: b64('"https://chatgpt.com"') },
      { headerKey: "signature-input", headerValue: b64('sig1=("@authority" "signature-agent");created=1739450000') },
      { headerKey: "accept", headerValue: b64("*/*") },
      { headerKey: "cookie", headerValue: b64("session=secret") },
    ],
  },
};

test("produces a valid Obsero payload", async () => {
  const payload = toPayload(toObseroEvent(entry));

  assert.deepEqual(validateEvent(payload), []);
  assert.equal(payload.path, "/pricing");
  assert.equal(payload.method, "GET");
  assert.equal(payload.statusCode, 200);
  assert.match(payload.headers["user-agent"], /ChatGPT-User/);
});

test("the domain header goes beside the payload, not in it", async () => {
  const event = toObseroEvent(entry);

  assert.equal(event.domain, "acme.com");
  assert.deepEqual(Object.keys(toPayload(event)).sort(), [
    "headers",
    "method",
    "path",
    "statusCode",
  ]);
});

test("Web Bot Auth headers survive byte-for-byte", async () => {
  const { headers } = toObseroEvent(entry);

  assert.equal(headers["signature-agent"], '"https://chatgpt.com"');
  assert.equal(
    headers["signature-input"],
    'sig1=("@authority" "signature-agent");created=1739450000',
  );
});

test("excluded headers never leave", async () => {
  const { headers } = toObseroEvent(entry);

  assert.equal(headers.cookie, undefined);
});

test("skipped paths are dropped", async () => {
  const health = { httpRequest: { requestUrl: "https://acme.com/health", status: 200 } };

  assert.equal(toObseroEvent(health), null);
});

test("requestUrl splits into path and query", async () => {
  assert.deepEqual(splitUrl("https://acme.com/pricing?ref=hn"), {
    path: "/pricing",
    query: "ref=hn",
    host: "acme.com",
  });
});

test("a value that is not really base64 is kept verbatim", async () => {
  assert.equal(decodeHeaderValue("not base64 at all!"), "not base64 at all!");
});

test("a push envelope unwraps to its log entry", async () => {
  const body = { message: { data: Buffer.from(JSON.stringify(entry)).toString("base64") } };

  assert.deepEqual(decodeEntries(body), [entry]);
});
