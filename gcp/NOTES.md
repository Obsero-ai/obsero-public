# GCP: measured behaviour and gotchas

Everything here was observed on a live deployment, not inferred from docs. It
is separated from the README because none of it is needed to *use* the module —
only to trust its numbers, or to hand-build the pipeline yourself.

## How this maps to the AWS build

| AWS | GCP | Notes |
|---|---|---|
| CloudFront | Cloud CDN + external Application LB | |
| Real-time logs → Kinesis | — | no equivalent needed |
| Standard logging v2 | LB request logging | GCP's carries named headers; CloudFront's does not |
| Kinesis Data Stream (~$11/mo) | Pub/Sub | no idle cost, no shards |
| Firehose | Pub/Sub subscription | retries + backoff are native |
| Adapter Lambda + Function URL | Cloud Run service | scales to zero |
| Firehose S3 backup bucket | dead-letter topic | replayable as a queue |
| `X-Amz-Firehose-Access-Key` shared secret | OIDC token on push | real identity, not a shared secret |
| `LogDeliveryEnabled` tag trap | — | not applicable |

## What the logged headers actually look like

Verified against a live entry. The allow-list lands under
`jsonPayload.loggingHttpRequestHeaders`, as an **array of pairs**, with every
value **base64-encoded**:

```json
"loggingHttpRequestHeaders": [
  { "headerKey": "from",            "headerValue": "Ym90QG9wZW5haS5jb20=" },
  { "headerKey": "signature-agent", "headerValue": "Imh0dHBzOi8vY2hhdGdwdC5jb20i" }
]
```

Three consequences:

- **The base64 is a feature.** It is why Web Bot Auth signatures survive
  byte-for-byte — quotes, commas and embedded colons included. CloudFront's
  percent-encoded `cs-headers` needed careful splitting on `%0A` *before*
  decoding, or a header value could forge an extra header. Nothing here can.
- **An absent header is simply missing from the array.** There is no
  empty-string placeholder to distinguish "not sent" from "sent empty".
- **`httpRequest.userAgent` and `httpRequest.remoteIp` are populated
  regardless**, confirming those slots are free and should not be spent on the
  allow-list.

The count limit is 10, enforced by the API on update:

```
Invalid value for field 'resource.logConfig': At most 10
logging_http_request_headers can be specified per BackendService.
```

`sec-fetch-mode` and `sec-fetch-site` were the two cut from the default list.
`sec-fetch-*` is mostly a presence signal — bots send none of it — so one of
the three carries nearly the same information, and `sec-fetch-mode` is the one
the harness cannot send faithfully anyway (Node's `fetch` forces it to `cors`).

⚠️ Still unverified: per-header value truncation.

## Backend buckets produce no request logs

`BackendBucket` in the Compute v1 API has **no `logConfig` field at all**. A
static site served straight from Cloud Storage through Cloud CDN emits no LB
request logs, so there is nothing to ship.

This is why the demo site does not port directly from AWS: the origin must be a
backend **service**, so `site/` serves the same static pages from Cloud Run
behind a serverless NEG instead (see `site/server.mjs`). Real customers are
mostly unaffected — apps on Cloud Run, GKE or a MIG already use backend
services — but a customer fronting a pure GCS bucket cannot be onboarded
without changing their origin.

## Terraform cannot set the header list

Both `hashicorp/google` and `hashicorp/google-beta` (v7) expose `log_config`
with only `enable`, `optional_fields`, `optional_mode` and `sample_rate`.
`loggingHttpRequestHeaders` is **not in either provider**, though the API and
`gcloud` both support it. The module therefore shells out to `gcloud` from a
`terraform_data` + `local-exec`.

### The allow-list survives Terraform only if it is re-asserted

The worst of the gotchas, because it fails silently and `terraform plan`
reports nothing wrong.

The first version keyed the shell-out on a hash of the inputs and paired it
with a destroy-time provisioner that removed the list again. On the next full
`terraform apply` that destroy provisioner fired during a replacement and wrote
back a `logConfig` with no `loggingHttpRequestHeaders` — confirmed in the audit
log:

```
08:11:24  v1.compute.backendServices.update
          logConfig: {"enable": true, "optionalMode": "EXCLUDE_ALL_OPTIONAL", "sampleRate": "1.0"}
```

Logs kept flowing. They simply arrived with nothing to classify on, and
`terraform plan` said "No changes" because Terraform cannot see a field it does
not model.

The fix is two resources rather than one. `terraform_data.request_logging`
triggers on `timestamp()`, so every apply re-installs the list and any drift
heals itself. Removal moved to `terraform_data.request_logging_cleanup`, whose
triggers never change, so it fires only on a genuine `terraform destroy`.

The cost is one unavoidable change in every plan. That is the honest trade: an
invisible failure of the pipeline's whole purpose, against a noisy plan.

## Config changes take minutes to reach the edge

After re-installing the allow-list, requests sent ~60 seconds later were still
logged with no headers. The same probe at ~10 minutes carried all of them. So a
`terraform apply` that touches the allow-list leaves a window where traffic is
logged headerless, with no signal that it is happening.

Budget several minutes before trusting a run taken straight after an apply, and
treat a sudden run of headerless events after a deploy as propagation rather
than breakage.

## One log entry per push delivery

The adapter logged `forwarded { count: 1 }` for every message across the run.
Pub/Sub push carries exactly one log entry. The adapter still handles a batch,
since that behaviour is not contractual, but the design assumption holds.

## Excluding from `_Default` really does hide the logs

Once `exclude_from_default_bucket` takes effect, `gcloud logging read` returns
nothing for the load balancer — the entries are routed but never stored. That
is the intended saving, and it means **Pub/Sub is the only place to read raw
entries**. `make sample` reads storage, so it goes quiet once the exclusion
lands; pull the verify subscription instead.

## Delivery is at-least-once

A push that fails after the adapter already forwarded some of its events is
retried whole. After `max_delivery_attempts` the message parks on the
dead-letter topic, where it stays queued and replayable — better than
Firehose's gzip-in-a-bucket, which is the AWS equivalent.

## Building the adapter image

`terraform apply` builds and pushes a container unless you set `adapter_image`.
That needs `docker` and an authenticated `gcloud` on the machine running apply.

The image is built locally rather than through Cloud Build because in a
default-configured project Cloud Build runs as the default compute service
account, which cannot read its own staging bucket. A local build needs only
`docker` and a configured credential helper, and is faster besides.

## Open questions

Everything here still needs a test.

- Per-header value truncation in `loggingHttpRequestHeaders`. The count limit
  is answered: 10, and nothing in a 40-request run came back truncated.
- Log delivery latency. Observed at roughly 30–60s end to end, better than
  CloudFront standard logging's 1–2 minutes but not the seconds hoped for.
- Whether request logging is sampled independently of `sample_rate` under load,
  the way CloudFront real-time logs turned out to be best-effort. Three runs of
  40 delivered 39, 40 and 40 — no evidence of loss, but far too small a sample
  to call it exact.
- Current forwarding-rule and data-processing pricing.

## Harness caveat

Node's `fetch` overrides `sec-fetch-mode` to `cors` and adds
`connection: keep-alive`, so those two fields in a `make traffic` run do not
reflect a real browser. Every User-Agent and every other header passes through
untouched.
