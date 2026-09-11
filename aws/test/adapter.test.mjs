/**
 * Runs the real adapter parser over sample CloudFront log lines and checks the
 * resulting payload against the Obsero contract. No AWS account needed:
 *
 *   make test
 *
 * If you rewrite the adapter for your own log source, change the fixtures and
 * keep the assertions -- they are what Obsero actually requires.
 */
import test from "node:test";
import assert from "node:assert/strict";
import { validateEvent } from "../../obsero.mjs";

const ADAPTER = "../ingestion/lambda/adapter/index.mjs";

/** Fresh module instance: the adapter reads its config from env at import. */
async function loadAdapter(env) {
  Object.assign(process.env, env);
  return import(`${ADAPTER}?${new URLSearchParams(env)}`);
}

// --- standard logging v2: JSON with named fields ---------------------------

const STANDARD_FIELDS = { LOG_FORMAT: "standard-json" };

const standardLine = JSON.stringify({
  "cs-uri-stem": "/pricing",
  "cs-uri-query": "ref=hn",
  "cs-method": "GET",
  "sc-status": "200",
  "x-host-header": "acme.com",
  "cs(User-Agent)": "Mozilla/5.0%20(compatible;%20GPTBot/1.2;%20+https://openai.com/gptbot)",
  "cs(Referer)": "https://news.ycombinator.com/",
});

test("standard: produces a valid Obsero payload", async () => {
  const { toObseroEvent, toPayload } = await loadAdapter(STANDARD_FIELDS);
  const event = toObseroEvent(standardLine);

  assert.deepEqual(validateEvent(toPayload(event)), []);
  assert.equal(event.path, "/pricing");
  assert.equal(event.method, "GET");
  assert.equal(event.statusCode, 200);
  assert.equal(event.domain, "acme.com");
  assert.match(event.headers["user-agent"], /GPTBot/);
});

test("standard: the domain header goes beside the payload, not in it", async () => {
  const { toObseroEvent, toPayload } = await loadAdapter(STANDARD_FIELDS);
  const payload = toPayload(toObseroEvent(standardLine));

  assert.deepEqual(Object.keys(payload).sort(), [
    "headers",
    "method",
    "path",
    "statusCode",
  ]);
});

test("standard: skipped paths are dropped", async () => {
  const { toObseroEvent } = await loadAdapter(STANDARD_FIELDS);
  const line = JSON.stringify({ "cs-uri-stem": "/health", "cs-method": "GET", "sc-status": "200" });

  assert.equal(toObseroEvent(line), null);
});

// --- real-time logs: positional TSV, full viewer headers -------------------

const REALTIME_FIELDS = [
  "timestamp", "sc-status", "cs-method", "cs-uri-stem", "x-host-header", "cs-headers",
];

const REALTIME_ENV = {
  LOG_FORMAT: "realtime-tsv",
  CLOUDFRONT_LOG_FIELDS: REALTIME_FIELDS.join(","),
};

// cs-headers: percent-encoded "name:value" pairs joined by %0A.
const realtimeLine = [
  "1739450000.123",
  "200",
  "GET",
  "/pricing?ref=hn", // real-time logs put the query string in cs-uri-stem
  "acme.com",
  [
    "host:acme.com",
    "user-agent:Mozilla/5.0%20(compatible;%20ChatGPT-User/1.0;%20+https://openai.com/bot)",
    "signature-agent:%22https://chatgpt.com%22",
    "cookie:session=secret",
  ].join("%0A"),
].join("\t");

test("realtime: full headers survive, path loses the query string", async () => {
  const { toObseroEvent, toPayload } = await loadAdapter(REALTIME_ENV);
  const payload = toPayload(toObseroEvent(realtimeLine));

  assert.deepEqual(validateEvent(payload), []);
  assert.equal(payload.path, "/pricing");
  assert.equal(payload.headers["signature-agent"], '"https://chatgpt.com"');
  assert.match(payload.headers["user-agent"], /ChatGPT-User/);
});

test("realtime: excluded headers never leave", async () => {
  const { toObseroEvent } = await loadAdapter(REALTIME_ENV);
  const event = toObseroEvent(realtimeLine);

  assert.equal(event.headers.cookie, undefined);
});

test("realtime: a header value that decodes to a newline cannot forge a header", async () => {
  const { parseHeaders } = await loadAdapter(REALTIME_ENV);
  const headers = parseHeaders({
    "cs-headers": "user-agent:curl/8.5%250Ax-forged:yes",
  });

  assert.equal(headers["x-forged"], undefined);
});
