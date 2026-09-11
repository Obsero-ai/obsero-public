# AGENTS.md — AWS

Read [`../AGENTS.md`](../AGENTS.md) first; it has the contract and the rules
that apply everywhere. This file is the AWS-specific playbook: what to check,
in what order, and what each failure actually means.

```
viewer -> CloudFront -> Firehose -> adapter Lambda (Function URL) -> POST /v1/events
                                          \-> S3 backup bucket (undeliverable batches)
```

```
ingestion/  the Terraform module a customer consumes. One module block.
site/       the demo rig: private S3 bucket + CloudFront, and one module block
            wiring the pipeline to it. Both halves are ONE Terraform stack.
test/       traffic harness, runs on the dev's machine. 19 client personas.
```

## Read in this order

1. `README.md` — how a customer wires the module into their own distribution
2. `NOTES.md` — behaviour measured on a live deployment. Read it before you
   diagnose anything; four of the five things devs report as bugs are in there.
3. `ingestion/README.md` — every module input and output
4. `ingestion/lambda/adapter/index.mjs` — the three-part adapter

## Getting a dev set up

```bash
cd aws
make test                                        # no AWS account needed
make event TOKEN=<tracking-id> DOMAIN=acme.com   # is the token accepted?
```

Both of those pass or fail in seconds and rule out most confusion before any
infrastructure exists. Then:

```bash
../setup.sh aws            # menu: 1 site, 2 pipeline, 3 destroy
```

or the individual make targets (`make` alone lists them all): `deploy`,
`traffic`, `check`, `logs`, `failures`, `destroy`, `leftovers`.

`setup.sh`'s step 1 is a targeted apply of the site resources only
(`aws_s3_object.site`, `aws_s3_bucket_policy.site`,
`aws_cloudfront_distribution.site` and the two bucket settings). Step 2 is the
plain untargeted apply, which adds `module.ingestion`. `make deploy` does both
at once — fine, just slower to a first signal.

### Preflight you should run yourself

```bash
aws sts get-caller-identity          # authenticated at all?
terraform -chdir=site/terraform validate
```

The stack needs permission to create S3 buckets, a CloudFront distribution and
its OAC, a Firehose delivery stream, a Lambda plus its Function URL, IAM roles,
CloudWatch log groups, and — in `realtime` mode — a Kinesis stream. Nothing
exotic, but a scoped-down CI role usually lacks `iam:CreateRole` and
`cloudfront:CreateDistribution`.

## The one real decision: which log source

`log_source` is the choice CloudFront forces on you. The demo site uses
`standard`.

| | `standard` (default) | `realtime` |
|---|---|---|
| idle cost | **none** | ~$11/mo per Kinesis shard |
| latency | ~1–2 min | seconds |
| headers | User-Agent, Referer, Host, X-Forwarded-For | **full viewer header set** |
| Web Bot Auth signatures | **no** | yes |
| client hints (`sec-ch-ua`) | **no** | yes |

If a dev wants to *verify* an agent rather than trust its User-Agent, they need
`realtime` — standard logging v2 has no `cs-headers` field, so
`signature-agent` / `signature-input` / `signature` never arrive at all. Say
that directly; it is not a tuning problem.

`standard` needs `distribution_arn`. `realtime` instead exports
`realtime_log_config_arn`, which the dev attaches to each cache behaviour they
want logged — so it can be rolled out one path pattern at a time. Behaviours
without the ARN emit nothing. Examples for both shapes are in
`ingestion/examples/`.

## Symptom → cause → fix

| symptom | almost certainly | what to do |
|---|---|---|
| Nothing arrives at Obsero, everything reports healthy, Kinesis `IncomingRecords` is 0 | the `LogDeliveryEnabled = true` tag is missing from the Firehose stream (standard mode) | the module applies it automatically. If someone hand-built the stream, add it. There is **no error message** for this anywhere. |
| Nothing yet, and the deploy finished under a minute ago | the 60–90s latency floor | wait. CloudFront flushes continuously but Firehose buffers for at least 60s, and that is not a knob. |
| 10 of 30 requests missing, no pattern by status/path/client (realtime) | CloudFront delivers real-time logs **best-effort** | not a bug and not fixable from here. Measured: 4 of 5 runs delivered 100%, one delivered 20/30. Treat counts as a high-fidelity sample, never a ledger. Do not reconcile against origin logs or bill on them. |
| Duplicate events in Obsero | delivery is at-least-once | one failed event fails its whole Firehose batch, which is then retried, duplicating the events that already landed. Expected. |
| Every column in a parsed record is shifted (realtime) | CloudFront emits fields in **its own** canonical order, ignoring the log config, with no header row | the module sorts `log_fields` canonically and hands the same list to the adapter; `log_fields_in_order` exports it. Never trust the config's order positionally. |
| Analytics shows one page per query string | `cs-uri-stem` includes the query string in real-time logs (unlike standard access logs) | the adapter strips it. If a custom parser is in play, strip it there. |
| Adapter returns 429, events land in the backup bucket | Lambda concurrency exhausted | new accounts cap at **10 concurrent executions** account-wide, and at that ceiling `reserved_concurrent_executions` cannot be set at all. Nothing is lost — replay the backup bucket. Watch `Throttles`. |
| `terraform destroy` refuses to delete a bucket | it holds objects Terraform did not create — exactly what the backup bucket collects | use `../destroy.sh aws`, which empties it first. The module keeps `backup_force_destroy = false` on purpose so a customer's destroy *stops* rather than discarding events that never reached Obsero. The demo site sets it to `true`. |
| A distribution survives the destroy | CloudFront needs two operations minutes apart | `destroy.sh` reports it rather than pretending: disable it, wait for `Deployed`, then delete. |
| `sec-fetch-mode` is `cors` in a traffic run and `connection: keep-alive` appeared | Node's `fetch` overrides both | harness artefact only. Every User-Agent and every other header passes through untouched. |

## Verifying it actually works

```bash
make logs                    # follow the adapter forwarding, live
make check                   # score the last traffic run
make failures                # batches the endpoint never accepted
```

`make check` reads the records back, replays them through the **real** adapter
parser, correlates the `?mt=<runId>-<seq>` tag on every request, and diffs
headers sent against headers received. Baseline to compare against: 78/78
correlated, zero header loss.

The demo site sets `debug_log_events = true`, so every forwarded event and one
raw record per batch land in CloudWatch. That multiplies log volume by the
request rate — tell devs to turn it off for anything real.

## Changing the adapter

Rewrite parts 2 and 3, leave part 1 alone, then:

```bash
make test
```

It feeds sample log lines through the dev's parser and checks the payload
against `validateEvent`. Fixtures are in `test/adapter.test.mjs` — add one for
any new log shape rather than testing against live traffic.

## Cost and teardown

Lambda, CloudFront and S3 at demo volume sit inside the free tier. Kinesis has
no free tier: one shard is ~$11/month and is `realtime`'s floor. `standard` has
no idle cost and only reaches $11/month at roughly 380M requests.

```bash
../setup.sh aws destroy   # or: make destroy
make leftovers            # report what is still deployed, delete nothing
```
