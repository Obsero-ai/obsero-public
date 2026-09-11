#!/usr/bin/env node
/**
 * Send a fixed number of requests to the mock site as a realistic mix of
 * browsers, AI agents and crawlers, so Obsero's header-based classification
 * can be checked against known-correct expectations.
 *
 * Every request carries ?mt=<runId>-<seq> so check-ingest.mjs can correlate
 * what arrived with what was sent, request by request.
 *
 *   node test/mock-traffic.mjs -n 40
 *   node test/mock-traffic.mjs -n 20 --kind ai-agent
 *   node test/mock-traffic.mjs --only gptbot,chatgpt-user -n 10
 *   node test/mock-traffic.mjs --list
 */
import { writeFileSync, mkdirSync } from "node:fs";
import { dirname, join } from "node:path";
import { fileURLToPath } from "node:url";
import { execSync } from "node:child_process";
import { PERSONAS, KINDS } from "./personas.mjs";

const HERE = dirname(fileURLToPath(import.meta.url));
const PATHS = ["/", "/about.html", "/pricing.html", "/style.css", "/missing-page"];

const args = parseArgs(process.argv.slice(2));

if (args.help) {
  console.log(`
mock-traffic.mjs - send classified mock traffic at the site

  -n, --count <n>      total requests to send        (default 30)
  -c, --concurrency    requests in flight            (default 4)
      --delay <ms>     pause between requests        (default 120)
      --url <base>     target base URL               (default: terraform output)
      --kind <k,k>     restrict to kinds: ${KINDS.join(", ")}
      --only <id,id>   restrict to specific persona ids
      --path <p,p>     restrict to specific paths
      --seed <n>       deterministic persona/path selection
      --list           list personas and exit
      --dry-run        print the plan, send nothing
`);
  process.exit(0);
}

if (args.list) {
  const w = Math.max(...PERSONAS.map((p) => p.id.length));
  for (const kind of KINDS) {
    console.log(`\n${kind}`);
    for (const p of PERSONAS.filter((x) => x.kind === kind)) {
      console.log(`  ${p.id.padEnd(w)}  w=${String(p.weight).padStart(2)}  ${p.label}`);
    }
  }
  console.log();
  process.exit(0);
}

const baseUrl = (args.url ?? terraformOutput("site_url")).replace(/\/$/, "");
const total = Number(args.count ?? 30);
const concurrency = Number(args.concurrency ?? 4);
const delayMs = Number(args.delay ?? 120);

let pool = PERSONAS;
if (args.kind) {
  const want = split(args.kind);
  const bad = want.filter((k) => !KINDS.includes(k));
  if (bad.length) fail(`unknown kind(s): ${bad.join(", ")}. valid: ${KINDS.join(", ")}`);
  pool = pool.filter((p) => want.includes(p.kind));
}
if (args.only) {
  const want = split(args.only);
  const known = new Set(PERSONAS.map((p) => p.id));
  const bad = want.filter((id) => !known.has(id));
  if (bad.length) fail(`unknown persona id(s): ${bad.join(", ")}. try --list`);
  pool = pool.filter((p) => want.includes(p.id));
}
if (pool.length === 0) fail("no personas match those filters");

const paths = args.path ? split(args.path) : PATHS;
const rand = makeRandom(args.seed === undefined ? undefined : Number(args.seed));

// Build the full plan up front so --dry-run shows exactly what would be sent.
const runId = `${Date.now().toString(36)}${Math.floor(rand() * 1e4).toString(36)}`;
const plan = Array.from({ length: total }, (_, i) => {
  const persona = pickWeighted(pool, rand);
  return {
    seq: i,
    tag: `${runId}-${i}`,
    persona,
    path: paths[Math.floor(rand() * paths.length)],
  };
});

console.log(`target      ${baseUrl}`);
console.log(`run id      ${runId}`);
console.log(`requests    ${total}  (concurrency ${concurrency}, delay ${delayMs}ms)`);
console.log(`personas    ${pool.length} in pool\n`);

const planned = tally(plan.map((p) => p.persona.kind));
console.log("planned mix:");
for (const [kind, n] of planned) console.log(`  ${kind.padEnd(11)} ${n}`);
console.log();

if (args.dryRun) {
  for (const item of plan) {
    console.log(`  ${String(item.seq).padStart(3)}  ${item.persona.id.padEnd(20)} ${item.path}`);
  }
  process.exit(0);
}

const results = [];
let cursor = 0;
let sent = 0;

async function worker() {
  while (cursor < plan.length) {
    const item = plan[cursor++];
    const url = `${baseUrl}${item.path}?mt=${item.tag}`;
    const started = Date.now();
    let status = 0;
    let error;
    try {
      const res = await fetch(url, {
        method: "GET",
        headers: item.persona.headers,
        redirect: "manual",
        signal: AbortSignal.timeout(15_000),
      });
      status = res.status;
      await res.arrayBuffer();
    } catch (err) {
      error = String(err?.message ?? err);
    }
    results.push({
      seq: item.seq,
      tag: item.tag,
      personaId: item.persona.id,
      kind: item.persona.kind,
      vendor: item.persona.vendor ?? null,
      path: item.path,
      headers: item.persona.headers,
      status,
      error,
      ms: Date.now() - started,
    });
    sent++;
    process.stdout.write(
      `\r  sent ${String(sent).padStart(4)}/${total}  last: ${item.persona.id} ${item.path} -> ${error ? "ERR" : status}   `,
    );
    if (delayMs > 0) await sleep(delayMs);
  }
}

await Promise.all(
  Array.from({ length: Math.min(concurrency, plan.length) }, worker),
);
process.stdout.write("\n\n");

results.sort((a, b) => a.seq - b.seq);

const failed = results.filter((r) => r.error);
const statuses = tally(results.filter((r) => !r.error).map((r) => String(r.status)));
console.log("responses:");
for (const [code, n] of statuses) console.log(`  HTTP ${code}   ${n}`);
if (failed.length) console.log(`  errors    ${failed.length}  e.g. ${failed[0].error}`);

console.log("\nby persona:");
const perPersona = tally(results.map((r) => r.personaId));
const width = Math.max(...perPersona.map(([id]) => id.length));
for (const [id, n] of perPersona) {
  const kind = PERSONAS.find((p) => p.id === id).kind;
  console.log(`  ${id.padEnd(width)}  ${String(n).padStart(3)}  ${kind}`);
}

// The manifest is the ground truth check-ingest.mjs scores against.
const manifestPath = join(HERE, ".runs", `${runId}.json`);
mkdirSync(dirname(manifestPath), { recursive: true });
writeFileSync(
  manifestPath,
  JSON.stringify(
    { runId, baseUrl, startedAt: new Date().toISOString(), total, results },
    null,
    2,
  ),
);
writeFileSync(join(HERE, ".runs", "latest.json"), JSON.stringify({ runId }));

console.log(`\nmanifest    ${manifestPath}`);
console.log(`\nLog delivery takes ~30-60s. Then:  node test/check-ingest.mjs`);

// ---------------------------------------------------------------- helpers --

function parseArgs(argv) {
  const out = {};
  const alias = { n: "count", c: "concurrency", h: "help" };
  for (let i = 0; i < argv.length; i++) {
    const arg = argv[i];
    if (!arg.startsWith("-")) continue;
    const name = arg.replace(/^--?/, "");
    const key = alias[name] ?? camel(name);
    const next = argv[i + 1];
    if (next === undefined || next.startsWith("-")) out[key] = true;
    else out[key] = argv[++i];
  }
  return out;
}

// Declarations, not const arrows: parseArgs runs before this point in the file.
function camel(s) {
  return s.replace(/-([a-z])/g, (_, c) => c.toUpperCase());
}

function split(v) {
  return String(v).split(",").map((s) => s.trim()).filter(Boolean);
}

function sleep(ms) {
  return new Promise((r) => setTimeout(r, ms));
}

function pickWeighted(list, rand) {
  const total = list.reduce((sum, p) => sum + (p.weight ?? 1), 0);
  let roll = rand() * total;
  for (const item of list) {
    roll -= item.weight ?? 1;
    if (roll <= 0) return item;
  }
  return list[list.length - 1];
}

/** mulberry32, so --seed gives a reproducible mix. */
function makeRandom(seed) {
  if (seed === undefined || Number.isNaN(seed)) return Math.random;
  let a = seed >>> 0;
  return () => {
    a = (a + 0x6d2b79f5) >>> 0;
    let t = Math.imul(a ^ (a >>> 15), 1 | a);
    t = (t + Math.imul(t ^ (t >>> 7), 61 | t)) ^ t;
    return ((t ^ (t >>> 14)) >>> 0) / 4294967296;
  };
}

function tally(values) {
  const counts = new Map();
  for (const v of values) counts.set(v, (counts.get(v) ?? 0) + 1);
  return [...counts.entries()].sort((a, b) => b[1] - a[1]);
}

function terraformOutput(name) {
  try {
    return execSync(`terraform -chdir=${join(HERE, "..", "site", "terraform")} output -raw ${name}`, {
      encoding: "utf8",
      stdio: ["ignore", "pipe", "ignore"],
    }).trim();
  } catch {
    fail(`could not read terraform output "${name}" - pass --url instead`);
  }
}

function fail(msg) {
  console.error(`error: ${msg}`);
  process.exit(1);
}
