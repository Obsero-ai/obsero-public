# CloudFront -> Obsero

Streams every request hitting a CloudFront distribution to Obsero.

```
viewer -> CloudFront -> Firehose -> adapter Lambda -> POST /v1/events
```

```
ingestion/   the Terraform module you would actually ship
site/        a demo site to point it at
test/        traffic harness: 19 client personas, then score what arrived
```

Working with a coding agent? [`AGENTS.md`](AGENTS.md) next to this file has the
setup order, a symptom-to-fix table, and the things here that fail silently when
removed.

Everything runs in your own AWS account. The adapter strips `authorization`,
`cookie` and `set-cookie` before anything leaves it.

## Start here (no AWS account needed)

```bash
make test                                   # adapter payload vs the contract
make event TOKEN=<site-token> DOMAIN=acme.com   # POST one event, check the token
```

Then, if you want to watch it work end to end — `../setup.sh aws` walks through
it as a menu, or drive the same thing with make:

```bash
make deploy            # demo site + pipeline
make traffic N=40      # mock browser / AI-agent / crawler traffic
make check             # score what actually reached the endpoint
make logs              # follow the adapter forwarding, live
make destroy           # tear it all down again
```

`make` alone lists every task. `make e2e` does deploy → traffic → wait → score.

## Wiring it into your own distribution

One module block. The module **never touches your distribution** — it builds
the pipeline and hands back what you attach, so it works whether or not
Terraform manages your CloudFront.

```hcl
module "obsero_ingestion" {
  source = "./ingestion"

  name_prefix = "acme-prod"
  site_token  = var.obsero_site_token

  # standard: CloudFront delivers straight into Firehose. No idle cost.
  log_source       = "standard"
  distribution_arn = aws_cloudfront_distribution.site.arn
}
```

That is the whole integration for `standard`. For `realtime`, drop
`distribution_arn` and attach the exported ARN to each cache behaviour you want
logged instead:

```hcl
default_cache_behavior {
  # ...
  realtime_log_config_arn = module.obsero_ingestion.realtime_log_config_arn
}
```

Behaviours without the ARN emit nothing, so you can roll it out one path
pattern at a time. See `ingestion/examples/` for both shapes and
`ingestion/README.md` for every input.

## Which log source?

CloudFront makes you choose. This is the one real decision on AWS.

| | `standard` (default) | `realtime` |
|---|---|---|
| Idle cost | **none** | ~$11/mo per Kinesis shard |
| At 1M req/mo | ~$0.15 | ~$11 |
| Latency | ~1-2 min | seconds |
| Headers | User-Agent, Referer, Host, X-Forwarded-For | **full viewer header set** |
| Web Bot Auth signatures | no | **yes** |
| Client hints (`sec-ch-ua`) | no | **yes** |

Start on `standard`. Move to `realtime` when you want to *verify* an agent
rather than take its User-Agent at face value — standard logging v2 has no
`cs-headers` field, so `signature-agent` / `signature-input` / `signature`
never arrive at all.

(GCP has no such trade: it carries named headers on the cheap path. See
`../gcp/`.)

## Making it yours

The adapter is one file, in three parts:

`ingestion/lambda/adapter/index.mjs`

```
1. THE CONTRACT       build the payload and POST it   <- keep this
2. CLOUDFRONT         log line -> event               <- yours to rewrite
3. FIREHOSE PLUMBING  unwrap the batch, ack it        <- yours to rewrite
```

Change parts 2 and 3 to match your log source, leave part 1 alone, then run
`make test` — it feeds sample log lines through your parser and checks the
payload against the contract. Fixtures live in `test/adapter.test.mjs`.

Everything else is negotiable too: swap Firehose for anything, drop the backup
bucket, forward from your origin instead of the edge. Obsero only sees the
POST.

## test/ — the traffic harness

Runs on your machine, not in AWS. Sends a reproducible mix of traffic as 19
client personas, each carrying the headers that client really sends:

| kind | personas |
|---|---|
| `ai-agent` | ChatGPT-User, Claude-User, Perplexity-User, OAI-SearchBot, DuckAssistBot |
| `ai-crawler` | GPTBot, ClaudeBot, PerplexityBot, Meta-ExternalAgent, Bytespider, CCBot, Amazonbot |
| `human` | Chrome/Windows, Safari/iPhone, Firefox/macOS, Chrome/Android |
| `search-bot` | Googlebot, Bingbot, Applebot |

```bash
make traffic N=40                    # weighted mix
make traffic N=20 KIND=ai-agent      # one class
make traffic N=10 ONLY=gptbot SEED=7 # specific, reproducible
make personas                        # list them
```

Every request is tagged `?mt=<runId>-<seq>`. `make check` reads the records
back, replays them through the **real** adapter parser, correlates each tag,
and diffs headers sent against headers received. Measured over 78 requests:
78/78 correlated, zero header loss.

## Tearing it down

```bash
make destroy      # terraform destroy, then check nothing is left standing
make leftovers    # just tell me what is still deployed
```

Both call `../destroy.sh`, which empties the S3 buckets first — Terraform
refuses to delete a bucket holding objects it did not create, and that is
precisely what the backup bucket collects. See the [root README](../README.md)
for `--sweep` and the other flags.

The module itself keeps `backup_force_destroy = false`, so a customer's
`terraform destroy` will *stop* rather than silently discard events that never
reached Obsero. The demo site sets it to `true`, because nobody is going to
replay those.

## Before you trust the numbers

Four behaviours that are easy to mistake for bugs — all measured, all written
up in [NOTES.md](NOTES.md):

- **Real-time logs are best-effort.** One run in five dropped 10 of 30 requests
  before they ever reached Kinesis. Counts are a high-fidelity sample, not a
  ledger.
- **Delivery is at-least-once**, so a partially-failed batch can duplicate
  events that already landed.
- **60–90s of latency**, floored by Firehose's minimum buffer.
- **The `LogDeliveryEnabled` tag**, without which standard mode silently
  delivers nothing at all.
