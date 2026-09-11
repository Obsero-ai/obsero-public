#!/usr/bin/env node
/**
 * Score a mock-traffic run: pull the CloudFront records back out of Kinesis,
 * replay them through the *real* adapter parser, and compare what Obsero
 * received against what was actually sent.
 *
 * This is the header-fidelity check. CloudFront is the lossy step: it decides
 * which viewer headers reach cs-headers and how much of the field it keeps, so
 * the only way to know a classification header survived is to read it back.
 *
 *   node test/check-ingest.mjs                 # newest run
 *   node test/check-ingest.mjs --run <runId>
 *   node test/check-ingest.mjs --show chatgpt-user
 */
import { readFileSync, existsSync } from "node:fs";
import { dirname, join } from "node:path";
import { fileURLToPath } from "node:url";
import { execFileSync } from "node:child_process";

const HERE = dirname(fileURLToPath(import.meta.url));
const args = parseArgs(process.argv.slice(2));

const runId = args.run ?? latestRunId();
const manifestPath = join(HERE, ".runs", `${runId}.json`);
if (!existsSync(manifestPath)) fail(`no manifest for run ${runId}`);
const manifest = JSON.parse(readFileSync(manifestPath, "utf8"));

const logSource = args.source ?? terraformOutput("log_source");
const standard = logSource === "standard";
const fnName = args.function ?? terraformOutput("adapter_function");

// Realtime mode parses positionally, so the field order must come from the
// deployed Lambda rather than a local guess. Standard mode is named JSON.
const fields = standard ? [] : lambdaEnv(fnName, "CLOUDFRONT_LOG_FIELDS").split(",");
if (!standard) {
  process.env.CLOUDFRONT_LOG_FIELDS = fields.join(",");
}
const { toObseroEvent } = standard
  ? { toObseroEvent: null }
  : await import("../ingestion/lambda/adapter/index.mjs");

console.log(`run         ${runId}  (${manifest.total} requests)`);
console.log(`mode        ${logSource}` + (standard ? "  (CloudFront standard logging v2)" : "  (real-time logs via Kinesis)"));
console.log(`started     ${manifest.startedAt}`);

const since = new Date(new Date(manifest.startedAt).getTime() - 120_000);
const wanted = new Map(manifest.results.map((r) => [r.tag, r]));

const deadline = Date.now() + Number(args.timeout ?? 300) * 1000;
let arrived = new Map();

while (Date.now() < deadline) {
  arrived = standard
    ? collectFromAdapterLogs(fnName, since, wanted)
    : collectFromKinesis(terraformOutput("kinesis_stream"), since, fields, wanted);
  if (arrived.size >= wanted.size) break;
  process.stdout.write(
    `\r  matched ${arrived.size}/${wanted.size} - waiting for CloudFront flush...   `,
  );
  await sleep(15_000);
}
process.stdout.write("\r".padEnd(70) + "\r");

// ------------------------------------------------------------- reporting ---

const missing = [...wanted.keys()].filter((tag) => !arrived.has(tag));
console.log(`\ndelivered   ${arrived.size}/${wanted.size} requests correlated by ?mt= tag`);
if (missing.length) {
  const skipped = missing.filter((t) => ["/health", "/favicon.ico"].includes(wanted.get(t).path));
  console.log(`missing     ${missing.length}` + (skipped.length ? ` (${skipped.length} intentionally skipped paths)` : ""));
}

// Header fidelity: what did we send vs what did Obsero actually get to see?
const EXPECTED_DROPS = new Set(["authorization", "cookie", "set-cookie"]);
// CloudFront standard logging v2 has no cs-headers field, so only these can
// ever reach the endpoint. Anything else missing is by design, not a defect.
const STANDARD_AVAILABLE = new Set(["host", "user-agent", "referer", "x-forwarded-for"]);
const lost = new Map();
const seenPersona = new Map();

for (const [tag, got] of arrived) {
  const sentReq = wanted.get(tag);
  const sentNames = Object.keys(sentReq.headers).map((h) => h.toLowerCase());
  const gotNames = new Set(Object.keys(got.event.headers));
  for (const name of sentNames) {
    if (EXPECTED_DROPS.has(name)) continue;
    if (standard && !STANDARD_AVAILABLE.has(name)) continue;
    if (!gotNames.has(name)) {
      if (!lost.has(name)) lost.set(name, new Set());
      lost.get(name).add(sentReq.personaId);
    }
  }
  if (!seenPersona.has(sentReq.personaId)) seenPersona.set(sentReq.personaId, { tag, sentReq, got });
}

console.log("\nheader fidelity through CloudFront:");
if (standard) {
  console.log("  mode exposes only: host, user-agent, referer, x-forwarded-for");
  console.log("  (standard logging v2 has no cs-headers field -- signature");
  console.log("   headers and client hints are unavailable by design)");
}
if (lost.size === 0) {
  console.log(standard
    ? "  every header this mode CAN carry arrived intact"
    : "  all sent headers survived into the Obsero payload");
} else {
  for (const [name, personas] of [...lost.entries()].sort()) {
    console.log(`  DROPPED  ${name.padEnd(28)} (${[...personas].join(", ")})`);
  }
}

// Classification signal: does each persona still carry an identifiable UA?
console.log("\nper-persona, as Obsero receives it:");
const rows = [...seenPersona.entries()].sort((a, b) =>
  (a[1].sentReq.kind + a[0]).localeCompare(b[1].sentReq.kind + b[0]),
);
let lastKind = null;
for (const [personaId, { sentReq, got }] of rows) {
  if (sentReq.kind !== lastKind) {
    console.log(`\n  [${sentReq.kind}]`);
    lastKind = sentReq.kind;
  }
  const ua = got.event.headers["user-agent"] ?? "(none)";
  const n = [...arrived.values()].filter((a) => wanted.get(a.tag)?.personaId === personaId).length;
  console.log(`    ${personaId.padEnd(20)} x${String(n).padStart(3)}  ua: ${truncate(ua, 76)}`);
  const extras = Object.keys(got.event.headers).filter((h) =>
    ["signature-agent", "signature-input", "signature", "from"].includes(h),
  );
  if (extras.length) console.log(`    ${" ".repeat(20)}       auth: ${extras.join(", ")}`);
}

if (args.show) {
  const entry = seenPersona.get(args.show);
  if (!entry) fail(`persona "${args.show}" not present in this run`);
  console.log(`\nfull Obsero payload for ${args.show}:`);
  console.log(JSON.stringify(entry.got.event, null, 2));
  console.log(`\nheaders originally sent:`);
  console.log(JSON.stringify(entry.sentReq.headers, null, 2));
}

console.log();
if (missing.length) process.exitCode = 1;

// ---------------------------------------------------------------- helpers --

/** Drain every shard from `since`, parse each line, keep the ones we tagged. */
/**
 * Standard mode has no Kinesis stream to replay, so read the events back out of
 * the adapter's own debug log. Requires debug_log_events = true on the module.
 */
function collectFromAdapterLogs(fnName, since, wanted) {
  const found = new Map();
  const group = `/aws/lambda/${fnName}`;
  let token;

  do {
    const argv = [
      "logs", "filter-log-events",
      "--log-group-name", group,
      "--start-time", String(since.getTime()),
      "--filter-pattern", "event",
      "--max-items", "10000",
      "--output", "json",
    ];
    if (token) argv.push("--starting-token", token);

    let page;
    try {
      page = JSON.parse(aws(argv));
    } catch {
      break;
    }
    for (const entry of page.events ?? []) {
      const match = /\bevent (\{.*\})\s*$/.exec(entry.message ?? "");
      if (!match) continue;
      let event;
      try {
        event = JSON.parse(match[1]);
      } catch {
        continue;
      }
      const tag = /(?:^|&)mt=([^&]+)/.exec(event.query ?? "")?.[1];
      if (!tag || !wanted.has(tag) || found.has(tag)) continue;
      found.set(tag, { tag, event });
    }
    token = page.nextToken ?? page.NextToken;
  } while (token);

  if (found.size === 0) {
    console.error(
      "\n  no events found in the adapter log. Standard mode scoring needs\n" +
      "  debug_log_events = true on the ingestion module.\n",
    );
  }
  return found;
}

/** Drain every shard from `since`, parse each line, keep the ones we tagged. */
function collectFromKinesis(streamName, since, fields, wanted) {
  const found = new Map();
  const shards = JSON.parse(
    aws(["kinesis", "list-shards", "--stream-name", streamName, "--output", "json"]),
  ).Shards;

  const queryIdx = fields.indexOf("cs-uri-query");

  for (const shard of shards) {
    let iterator = JSON.parse(
      aws([
        "kinesis", "get-shard-iterator",
        "--stream-name", streamName,
        "--shard-id", shard.ShardId,
        "--shard-iterator-type", "AT_TIMESTAMP",
        "--timestamp", String(Math.floor(since.getTime() / 1000)),
        "--output", "json",
      ]),
    ).ShardIterator;

    for (let round = 0; round < 40 && iterator; round++) {
      const page = JSON.parse(
        aws(["kinesis", "get-records", "--shard-iterator", iterator, "--limit", "1000", "--output", "json"]),
      );
      for (const record of page.Records ?? []) {
        const text = Buffer.from(record.Data, "base64").toString("utf8");
        for (const line of text.split("\n")) {
          if (!line.trim()) continue;
          const values = line.split("\t");
          const query = decodeSafe(values[queryIdx] ?? "");
          const tag = /(?:^|&)mt=([^&]+)/.exec(query)?.[1];
          if (!tag || !wanted.has(tag) || found.has(tag)) continue;
          const event = toObseroEvent(line);
          if (event) found.set(tag, { tag, event, line });
        }
      }
      iterator = page.NextShardIterator;
      if ((page.Records ?? []).length === 0 && page.MillisBehindLatest === 0) break;
    }
  }
  return found;
}

function aws(argv) {
  return execFileSync("aws", argv, { encoding: "utf8", maxBuffer: 64 * 1024 * 1024 });
}

function lambdaEnv(name, key) {
  const value = aws([
    "lambda", "get-function-configuration",
    "--function-name", name,
    "--query", `Environment.Variables.${key}`,
    "--output", "text",
  ]).trim();
  if (!value || value === "None") fail(`lambda ${name} has no ${key}`);
  return value;
}

function terraformOutput(name) {
  try {
    return execFileSync("terraform", [`-chdir=${join(HERE, "..", "site", "terraform")}`, "output", "-raw", name], {
      encoding: "utf8", stdio: ["ignore", "pipe", "ignore"],
    }).trim();
  } catch {
    fail(`could not read terraform output "${name}"`);
  }
}

function latestRunId() {
  const p = join(HERE, ".runs", "latest.json");
  if (!existsSync(p)) fail("no runs yet - run mock-traffic.mjs first");
  return JSON.parse(readFileSync(p, "utf8")).runId;
}

function decodeSafe(v) {
  if (!v || v === "-") return "";
  try { return decodeURIComponent(v); } catch { return v; }
}

function truncate(s, n) {
  return s.length > n ? s.slice(0, n - 1) + "…" : s;
}

function parseArgs(argv) {
  const out = {};
  for (let i = 0; i < argv.length; i++) {
    if (!argv[i].startsWith("-")) continue;
    const key = argv[i].replace(/^--?/, "");
    const next = argv[i + 1];
    out[key] = next === undefined || next.startsWith("-") ? true : argv[++i];
  }
  return out;
}

function sleep(ms) {
  return new Promise((r) => setTimeout(r, ms));
}

function fail(msg) {
  console.error(`error: ${msg}`);
  process.exit(1);
}
