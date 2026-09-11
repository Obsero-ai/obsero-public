# ingestion/ — the Terraform module

Streams every HTTP request hitting a Cloud Load Balancing backend service to
Obsero. Reference for inputs, outputs and day-2 operations; see
[../README.md](../README.md) to get started and [../NOTES.md](../NOTES.md) for
measured behaviour.

```
viewer
  └─> Cloud CDN + external Application Load Balancer   (yours)
        └─ request logs, incl. an allow-list of request headers
             └─> Cloud Logging
                   └─> Log Router sink  (filtered to one backend service)
                         └─> Pub/Sub topic
                               └─> push subscription (OIDC)
                                     └─> Cloud Run adapter
                                           ├─> POST https://.../v1/events
                                           └─> dead-letter topic
```

## Usage

```hcl
module "obsero_ingestion" {
  source = "./ingestion" # or github.com/obsero/gcp-ingestion//ingestion?ref=v1

  project_id  = var.project_id
  name_prefix = "acme-prod"
  site_token  = var.obsero_site_token

  # The backend service whose traffic should be logged.
  backend_service_name = google_compute_backend_service.site.name
}
```

There is no ARN to attach to a cache behaviour the way the AWS module works.
The module configures logging on the named backend service directly. Better
DX, at the cost of mutating a resource you own — see *Operating notes*.

## Inputs

| Name | Default | Notes |
|---|---|---|
| `project_id` | — | required |
| `name_prefix` | — | required, 2–39 lowercase alphanumeric/hyphen |
| `backend_service_name` | — | required, must be a backend **service** |
| `site_token` | — | required, sent as `x-obsero-key` |
| `region` | `us-central1` | Cloud Run adapter and its image repository |
| `ingest_url` | staging endpoint | must be https |
| `logged_headers` | 10 classification headers | the allow-list, capped at 10 |
| `sample_rate` | `1.0` | fraction of requests logged |
| `excluded_headers` | `authorization, cookie, set-cookie` | stripped before anything leaves |
| `skipped_paths` | `/health, /favicon.ico` | never forwarded |
| `adapter_image` | `null` | set to skip the local docker build |
| `max_delivery_attempts` | `5` | push attempts before dead-lettering |
| `message_retention` | `86400s` | |
| `exclude_from_default_bucket` | `true` | stop paying to store what is already routed |
| `create_verify_subscription` | `true` | extra pull subscription for a test harness |
| `debug_log_events` | `false` | logs every forwarded event |

## Outputs

`topic`, `dead_letter_topic`, `dead_letter_subscription`, `push_subscription`,
`verify_subscription`, `adapter_service`, `adapter_url`, `adapter_image`,
`sink_name`, `sink_writer_identity`, `logged_headers`, `backend_service`.

## The header allow-list

The reason this pipeline is cheaper than its AWS counterpart.

CloudFront forces a choice: standard logging is pay-as-you-go but carries only
User-Agent, Referer, Cookie and Host, while the full viewer header set needs
real-time logs and a ~$11/month Kinesis shard. GCP has no such trade —
`BackendServiceLogConfig.loggingHttpRequestHeaders` names the headers you want
and they arrive through the ordinary, cheap path.

The default list is what classification actually reads:

```
from,                                            # GPTBot, Googlebot
signature-agent, signature-input, signature,     # Web Bot Auth
accept, accept-language,                         # browsers vs */* bots
sec-ch-ua, sec-ch-ua-platform, sec-ch-ua-mobile, # client hints
sec-fetch-dest                                   # presence alone is the signal
```

**The Compute API caps this at 10 headers**, and rejects an eleventh outright.
Budget them: `user-agent`, `referer` and the client IP arrive as first-class
`httpRequest` fields whether or not you name them, so listing those would waste
slots. The adapter merges both sources, so they reach Obsero either way.

It is an allow-list, not "all headers". That is arguably the better default:
the payload carries only what classification needs, so nothing incidental
leaves your project.

## Operating notes

Five things worth knowing before trusting the numbers.

- **This module mutates your backend service.** It enables request logging and
  installs the header allow-list. Nothing else about the service is touched,
  and `terraform destroy` removes the allow-list again.

- **`terraform apply` shells out to `gcloud`, on every apply.** Neither
  `hashicorp/google` nor `google-beta` exposes `loggingHttpRequestHeaders`;
  `log_config` carries only `enable`, `optional_fields`, `optional_mode` and
  `sample_rate`. So the module runs a `local-exec` — and re-runs it every time,
  which is why you will always see one change in the plan.

  That is deliberate. Because Terraform cannot model the field, it also cannot
  notice it disappearing: any full-resource write to the backend service drops
  the allow-list while `plan` still reports no changes, and the pipeline keeps
  shipping events with nothing to classify on. Re-asserting on every apply
  makes that drift self-healing. Removal lives on a separate resource so it
  only runs on a real `terraform destroy`.

- **Allow-list changes take minutes to reach the edge.** After an apply that
  touches `logged_headers`, expect a window where requests are logged without
  them. Measured: still absent at ~60s, all present at ~10 minutes. A burst of
  headerless events straight after a deploy is propagation, not breakage.

- **`terraform apply` also builds a container**, unless you set
  `adapter_image`. That needs `docker` and an authenticated `gcloud` on the
  machine running apply.

- **Backend *buckets* produce no request logs.** `BackendBucket` has no
  `logConfig` field at all in the Compute v1 API, so a static site served
  straight from Cloud Storage through Cloud CDN emits nothing to ship. The
  origin has to be a backend service. Apps on Cloud Run, GKE or a MIG already
  are one; a pure GCS origin cannot be onboarded without changing it.

- **Reading raw entries means reading Pub/Sub.** With
  `exclude_from_default_bucket` on (the default), the entries are routed but
  never stored, so `gcloud logging read` returns nothing for the load balancer.
  That is the saving working as intended. Pull the verify subscription instead.

- **Delivery is at-least-once.** A push that fails after the adapter already
  forwarded some of its events will be retried whole. After
  `max_delivery_attempts` the message parks on the dead-letter topic, where it
  stays queued and replayable — better than Firehose's gzip-in-a-bucket, which
  is the AWS equivalent.

## Cost

Per 1M requests/month, ~1 KB per log entry:

| Component | Cost |
|---|---|
| Pub/Sub | ~$0.04 |
| Cloud Run adapter | $0 — free tier, scales to zero |
| Cloud Logging routing | $0 — routing to a sink is not charged |
| Cloud Logging storage | $0 with `exclude_from_default_bucket` |
| **Pipeline total** | **under $1/month** |

The load balancer itself is not free — roughly $18/month for the forwarding
rule plus per-GB processing — but customers already run one. It is only a cost
for a test rig built solely to produce traffic.

## Required roles

See [../PERMISSIONS.md](../PERMISSIONS.md). `roles/editor` alone is not enough.
