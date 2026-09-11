# Google Cloud -> Obsero

Streams every request hitting a Cloud Load Balancing backend service to Obsero.

```
viewer -> Cloud CDN + external Application LB -> Cloud Logging
       -> Log Router sink -> Pub/Sub -> Cloud Run adapter -> POST /v1/events
```

```
ingestion/   the Terraform module you would actually ship
site/        a demo site to point it at
test/        traffic harness: 19 client personas, then score what arrived
```

Working with a coding agent? [`AGENTS.md`](AGENTS.md) next to this file has the
setup order, a symptom-to-fix table, and the things here that fail silently when
removed.

Everything runs in your own project. The adapter strips `authorization`,
`cookie` and `set-cookie` before anything leaves it.

## Read this first

**Backend _buckets_ produce no request logs.** `BackendBucket` has no
`logConfig` field at all in the Compute v1 API, so a static site served
straight from a GCS bucket through Cloud CDN emits nothing to ship. Your origin
has to be a backend **service**.

Apps on Cloud Run, GKE or a MIG already are one and are unaffected. A pure GCS
origin has to change before it can be onboarded — which is why the demo site
here serves its static pages from Cloud Run rather than a bucket.

## Start here (no GCP project needed)

```bash
make test                                   # adapter payload vs the contract
make event TOKEN=<site-token> DOMAIN=acme.com   # POST one event, check the token
```

Then, if you want to watch it work end to end — `../setup.sh gcp` walks through
it as a menu, or drive the same thing with make:

```bash
make site              # site + LB + header logging only
make sample            # confirm the headers reach Cloud Logging
make deploy            # the rest: sink, Pub/Sub, adapter
make traffic N=40      # mock browser / AI-agent / crawler traffic
make check             # score what actually reached the endpoint
make destroy           # the load balancer bills at idle -- do this
```

`make` alone lists every task. `make e2e` does deploy → traffic → wait → score.

The two-stage start is deliberate: `make sample` confirms the header allow-list
behaves before you build anything downstream of it. See
[PERMISSIONS.md](PERMISSIONS.md) for the roles `terraform apply` needs — plain
`roles/editor` is not enough.

## Wiring it into your own load balancer

```hcl
module "obsero_ingestion" {
  source = "./ingestion"

  project_id  = var.project_id
  name_prefix = "acme-prod"
  site_token  = var.obsero_site_token

  backend_service_name = google_compute_backend_service.site.name
}
```

Unlike the AWS module there is no ARN to attach — this one configures logging
on the named backend service directly. Better DX, at the cost of mutating a
resource you own. It is reversible; `terraform destroy` takes the allow-list
back off.

`ingestion/README.md` has every input and output.

## The headline win: named request headers on the cheap path

CloudFront forces a choice — pay ~$11/month for real-time logs to get the full
header set, or take standard logging and lose everything but User-Agent. **GCP
has no such trade.** `BackendServiceLogConfig.loggingHttpRequestHeaders` names
the headers you want and they arrive through the ordinary, cheap path:

```
from,                                            # GPTBot, Googlebot
signature-agent, signature-input, signature,     # Web Bot Auth
accept, accept-language,                         # browsers vs */* bots
sec-ch-ua, sec-ch-ua-platform, sec-ch-ua-mobile, # client hints
sec-fetch-dest                                   # presence alone is the signal
```

**The API caps the list at 10** and rejects an eleventh outright. Ten is enough
only because `user-agent`, `referer` and the client IP arrive as first-class
`httpRequest` fields whether or not you name them — spending slots on those
would waste them. The adapter merges both sources.

It is an allow-list, not "all headers", which is arguably the better default:
the payload carries only what classification needs, so nothing incidental
leaves your project.

## Making it yours

The adapter is one file, in three parts:

`ingestion/adapter/index.mjs`

```
1. THE CONTRACT    build the payload and POST it   <- keep this
2. CLOUD LOGGING   log entry -> event              <- yours to rewrite
3. PUSH PLUMBING   unwrap the envelope, ack it     <- yours to rewrite
```

Change parts 2 and 3 to match your log source, leave part 1 alone, then run
`make test` — it feeds sample log entries through your parser and checks the
payload against the contract. Fixtures live in `test/adapter.test.mjs`.

## test/ — the traffic harness

Runs on your machine, not in GCP. Sends a reproducible mix of traffic as 19
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

Every request is tagged `?mt=<runId>-<seq>`. `make check` pulls the entries
from a verify subscription, replays them through the **real** adapter parser,
correlates each tag, and diffs headers sent against headers received. Measured
over 40 requests: 40/40 correlated, zero header loss — signature headers and
full client-hint sets byte-for-byte intact.

## Tearing it down

```bash
make destroy      # terraform destroy, then check nothing is left standing
make leftovers    # just tell me what is still deployed
```

Do this between runs. The forwarding rule bills at idle whether or not traffic
is flowing, and it is the single most expensive thing in the repo.

Both call `../destroy.sh`. See the [root README](../README.md) for `--sweep`,
which deletes leftovers rather than only reporting them — useful if a destroy
half-finishes, since a Cloud Run service or a backend service left behind will
not show up in any later plan.

Note that `terraform destroy` needs `project_id`, which has no default. Keep it
in `site/terraform/terraform.tfvars`; the script checks for it up front rather
than letting Terraform stall on a prompt.

## Cost

Per 1M requests/month, ~1 KB per log entry:

| Component | Cost |
|---|---|
| Pub/Sub | ~$0.04 |
| Cloud Run adapter | $0 — free tier, scales to zero |
| Cloud Logging routing | $0 — routing to a sink is not charged |
| Cloud Logging storage | $0 with `exclude_from_default_bucket` |
| **Pipeline total** | **under $1/month** |

The load balancer itself is **not** free — roughly $18/month for the forwarding
rule plus per-GB processing, whatever the traffic. That does not matter to a
customer who already runs one; it matters a lot for a demo rig that exists only
to make traffic. `make destroy` between runs.

⚠️ Confirm current forwarding-rule and data-processing pricing before quoting
any of these numbers to anyone.

## Before you trust the numbers

Behaviours that only surfaced once traffic was flowing — all measured, all
written up in [NOTES.md](NOTES.md):

- **`terraform apply` shells out to `gcloud` every time**, because no provider
  models the header allow-list. That is deliberate; the alternative fails
  silently.
- **Allow-list changes take minutes to reach the edge.** Headerless events
  straight after a deploy are propagation, not breakage.
- **Delivery is at-least-once**, dead-lettering to a replayable topic.
- **With `exclude_from_default_bucket` on, `gcloud logging read` returns
  nothing** for the load balancer. That is the saving working as intended.
