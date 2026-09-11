#!/usr/bin/env node
/**
 * Score a mock-traffic run: pull the load-balancer log entries back off the
 * verification subscription, replay them through the *real* adapter parser,
 * and compare what Obsero received against what was actually sent.
 *
 * This is the header-fidelity check. The load balancer is the lossy step: the
 * `--logging-http-request-headers` allow-list decides which viewer headers are
 * written at all and how much of each value survives, so the only way to know
 * a classification header made it is to read it back.
 *
 * Unlike the AWS harness there is no field-order to recover -- Cloud Logging
 * is self-describing JSON -- but the adapter's header filtering is still read
 * off the deployed service so local and deployed behaviour cannot drift.
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
const TF_DIR = join(HERE, "..", "site", "terraform");
const args = parseArgs(process.argv.slice(2));

const runId = args.run ?? latestRunId();
const manifestPath = join(HERE, ".runs", `${runId}.json`);
if (!existsSync(manifestPath)) fail(`no manifest for run ${runId}`);
const manifest = JSON.parse(readFileSync(manifestPath, "utf8"));

const project = args.project ?? gcloudConfig("project");
const subscription = args.subscription ?? terraformOutput("verify_subscription");
const adapterService = args.service ?? terraformOutput("adapter_service");
const region = args.region ?? "us-central1";

// Take the adapter's filtering config from the deployed revision, so a run is
// always scored against the parser that is actually running.
const adapterEnv = cloudRunEnv(adapterService, region);
process.env.EXCLUDED_HEADERS = adapterEnv.EXCLUDED_HEADERS ?? "";
process.env.SKIPPED_PATHS = adapterEnv.SKIPPED_PATHS ?? "";
// Keeps the adapter module from binding a port when imported for its parser.
process.env.NODE_ENV = "test";

const { toObseroEvent, decodeEntries } = await import(
  "../ingestion/adapter/index.mjs"
);

const loggedHeaders = new Set(
  terraformOutputJson("logged_headers").map((h) => h.toLowerCase()),
);

console.log(`run         ${runId}  (${manifest.total} requests)`);
console.log(`project     ${project}`);
console.log(`source      ${subscription}  (Pub/Sub pull, alongside the push subscription)`);
console.log(`started     ${manifest.startedAt}`);

const wanted = new Map(manifest.results.map((r) => [r.tag, r]));
const arrived = new Map();

const deadline = Date.now() + Number(args.timeout ?? 300) * 1000;
while (Date.now() < deadline) {
  collect(subscription, wanted, arrived);
  if (arrived.size >= wanted.size) break;
  process.stdout.write(
    `\r  matched ${arrived.size}/${wanted.size} - waiting for log delivery...   `,
  );
  await sleep(10_000);
}
process.stdout.write("\r".padEnd(70) + "\r");

// ------------------------------------------------------------- reporting ---

const missing = [...wanted.keys()].filter((tag) => !arrived.has(tag));
console.log(`\ndelivered   ${arrived.size}/${wanted.size} requests correlated by ?mt= tag`);
if (missing.length) {
  const skipped = missing.filter((t) =>
    ["/health", "/favicon.ico"].includes(wanted.get(t).path),
  );
  console.log(
    `missing     ${missing.length}` +
      (skipped.length ? ` (${skipped.length} intentionally skipped paths)` : ""),
  );
}

const EXPECTED_DROPS = new Set(["authorization", "cookie", "set-cookie"]);
// The load balancer reports these three whether or not they are asked for.
const ALWAYS_AVAILABLE = new Set(["host", "user-agent", "referer", "x-forwarded-for"]);
const lost = new Map();
const notRequested = new Set();
const seenPersona = new Map();

for (const [tag, got] of arrived) {
  const sentReq = wanted.get(tag);
  const gotNames = new Set(Object.keys(got.event.headers));
  for (const name of Object.keys(sentReq.headers).map((h) => h.toLowerCase())) {
    if (EXPECTED_DROPS.has(name)) continue;
    if (!loggedHeaders.has(name) && !ALWAYS_AVAILABLE.has(name)) {
      // Absent because nobody asked for it, not because it was lost.
      notRequested.add(name);
      continue;
    }
    if (!gotNames.has(name)) {
      if (!lost.has(name)) lost.set(name, new Set());
      lost.get(name).add(sentReq.personaId);
    }
  }
  if (!seenPersona.has(sentReq.personaId)) {
    seenPersona.set(sentReq.personaId, { tag, sentReq, got });
  }
}

console.log("\nheader fidelity through the load balancer:");
console.log(`  allow-list carries ${loggedHeaders.size} headers, plus host/x-forwarded-for`);
if (lost.size === 0) {
  console.log("  every allow-listed header arrived intact");
} else {
  for (const [name, personas] of [...lost.entries()].sort()) {
    console.log(`  DROPPED  ${name.padEnd(28)} (${[...personas].join(", ")})`);
  }
}
if (notRequested.size > 0) {
  console.log(
    `  not requested: ${[...notRequested].sort().join(", ")}`,
  );
  console.log("  (add them to logged_headers if classification needs them)");
}

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
  const n = [...arrived.values()].filter(
    (a) => wanted.get(a.tag)?.personaId === personaId,
  ).length;
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
  console.log(`\nraw log entry:`);
  console.log(JSON.stringify(entry.got.entry, null, 2));
}

console.log();
if (missing.length) process.exitCode = 1;

// ---------------------------------------------------------------- helpers --

/**
 * Drain the verification subscription, replaying each entry through the real
 * adapter parser. Messages are acked as they are read: the loop above polls
 * repeatedly, and without acking every poll would return the same backlog.
 */
function collect(sub, wanted, found) {
  for (let round = 0; round < 40; round++) {
    let batch;
    try {
      batch = JSON.parse(
        gcloud([
          "pubsub", "subscriptions", "pull", sub,
          "--project", project,
          "--limit", "1000",
          "--auto-ack",
          "--format", "json",
        ]),
      );
    } catch {
      return found;
    }
    if (!Array.isArray(batch) || batch.length === 0) return found;

    for (const received of batch) {
      const entries = safeDecode(received);
      for (const entry of entries) {
        const event = toObseroEvent(entry);
        if (!event) continue;
        const tag = /(?:^|&)mt=([^&]+)/.exec(event.query ?? "")?.[1];
        if (!tag || !wanted.has(tag) || found.has(tag)) continue;
        found.set(tag, { tag, event, entry });
      }
    }
  }
  return found;
}

/**
 * gcloud has shipped both base64 and already-decoded `data` over the years, so
 * decode through the adapter first and fall back to treating it as plain JSON.
 */
function safeDecode(received) {
  try {
    return decodeEntries({ message: received.message });
  } catch {
    try {
      const raw = received?.message?.data;
      const parsed = JSON.parse(typeof raw === "string" ? raw : "");
      return Array.isArray(parsed) ? parsed : [parsed];
    } catch {
      return [];
    }
  }
}

function cloudRunEnv(service, serviceRegion) {
  const json = JSON.parse(
    gcloud([
      "run", "services", "describe", service,
      "--project", project,
      "--region", serviceRegion,
      "--format", "json",
    ]),
  );
  const containers = json?.spec?.template?.spec?.containers ?? [];
  const env = {};
  for (const item of containers[0]?.env ?? []) {
    if (item?.name) env[item.name] = item.value ?? "";
  }
  return env;
}

function gcloud(argv) {
  return execFileSync("gcloud", argv, {
    encoding: "utf8",
    maxBuffer: 64 * 1024 * 1024,
  });
}

function gcloudConfig(key) {
  return gcloud(["config", "get-value", key]).trim();
}

function terraformOutput(name) {
  try {
    return execFileSync("terraform", [`-chdir=${TF_DIR}`, "output", "-raw", name], {
      encoding: "utf8",
      stdio: ["ignore", "pipe", "ignore"],
    }).trim();
  } catch {
    fail(`could not read terraform output "${name}"`);
  }
}

function terraformOutputJson(name) {
  try {
    return JSON.parse(
      execFileSync("terraform", [`-chdir=${TF_DIR}`, "output", "-json", name], {
        encoding: "utf8",
        stdio: ["ignore", "pipe", "ignore"],
      }),
    );
  } catch {
    fail(`could not read terraform output "${name}"`);
  }
}

function latestRunId() {
  const p = join(HERE, ".runs", "latest.json");
  if (!existsSync(p)) fail("no runs yet - run mock-traffic.mjs first");
  return JSON.parse(readFileSync(p, "utf8")).runId;
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
