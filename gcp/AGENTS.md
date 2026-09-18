# AGENTS.md — GCP

Read [`../AGENTS.md`](../AGENTS.md) first; it has the contract and the rules
that apply everywhere. This file is the GCP-specific playbook: what to check, in
what order, and what each failure actually means.

```
viewer -> Cloud CDN + external Application LB -> Cloud Logging
       -> Log Router sink -> Pub/Sub -> Cloud Run adapter -> POST /v1/events
                                     \-> dead-letter topic (replayable)
```

```
ingestion/  the Terraform module a customer consumes. One module block.
site/       the demo rig: static pages on Cloud Run behind an external
            Application LB. Both halves are ONE Terraform stack.
test/       traffic harness, runs on the dev's machine. 19 client personas.
```

## The blocker to raise before anything else

**Backend _buckets_ produce no request logs.** `BackendBucket` has no
`logConfig` field at all in the Compute v1 API, so a static site served straight
from Cloud Storage through Cloud CDN emits nothing to ship.

If a dev's origin is a plain GCS bucket, this pipeline cannot be onboarded
without changing their origin. Say so in the first reply — do not let them work
through a deploy first. Apps on Cloud Run, GKE or a MIG are already backend
**services** and are unaffected. This is also why the demo site serves its pages
from Cloud Run rather than a bucket.

## Read in this order

1. `README.md` — how a customer wires the module into their own load balancer
2. `PERMISSIONS.md` — **`roles/editor` alone is not enough**; check this before
   anyone runs apply
3. `NOTES.md` — behaviour measured on a live deployment, including the one
   Terraform trap that fails silently
4. `ingestion/README.md` — every module input and output
5. `ingestion/adapter/index.mjs` — the three-part adapter

## Getting a dev set up

```bash
cd gcp
make test                                        # no GCP project needed
make event TOKEN=<tracking-id> DOMAIN=acme.com   # is the token accepted?
```

Then:

```bash
../setup.sh gcp            # menu: 1 site, 2 pipeline, 4 destroy (3 connect is AWS-only)
```

`setup.sh` step 1 is a targeted apply of the site only
(`google_compute_global_forwarding_rule.site` plus the Cloud Run invoker
binding, which transitively pull the NEG, backend service, URL map, proxy,
address, Artifact Registry repo and the local image build). Step 2 is the plain
untargeted apply: the header allow-list, the sink, Pub/Sub and the adapter.

`make site` is the older two-stage split and additionally installs the header
allow-list, so `make sample` can prove headers arrive *before* anything
downstream exists. That is still the better sequence when a dev is debugging the
allow-list specifically.

### Preflight you should run yourself

```bash
gcloud config get-value project
gcloud auth print-access-token >/dev/null      # the provider wants ADC; this stands in
docker info >/dev/null                          # the images are built locally
```

Terraform's google provider wants Application Default Credentials.
`Makefile` and `setup.sh` both export `GOOGLE_OAUTH_ACCESS_TOKEN` from the
active gcloud login so the dev is not pushed into a second browser login;
`gcloud auth application-default login` works too.

### Roles — check these, do not assume

`roles/editor` deliberately excludes log-routing configuration and
resource-level `setIamPolicy`, which are the core of this pipeline. Beyond
Editor the identity needs:

| role | for |
|---|---|
| `roles/logging.configWriter` | the sink, and the `_Default` exclusion. **Not implied by Editor** — apply fails at the sink. |
| `roles/pubsub.admin` | `pubsub.topics.setIamPolicy`. **`roles/pubsub.editor` does not cover it** — without it the sink is created and silently publishes nothing. |
| `roles/run.admin` | the adapter and its invoker policy |
| `roles/iam.serviceAccountAdmin` | the two service accounts the module creates |

Check it directly rather than inferring from role names — there is no
`gcloud projects test-iam-permissions` subcommand, so use the REST call in
`PERMISSIONS.md`. An empty `permissions` array back means none are granted.

`setup.sh` checks the required APIs (`compute`, `run`, `pubsub`, `logging`,
`artifactregistry`, `iam`) and offers to enable them. It does **not** check
roles; do that yourself.

## The headline win, and its hard limit

`BackendServiceLogConfig.loggingHttpRequestHeaders` names the headers you want
and they arrive on the ordinary, cheap path. There is no AWS-style trade between
cost and header fidelity.

**The API caps the list at 10** and rejects an eleventh outright. Ten is enough
only because `user-agent`, `referer` and the client IP arrive as first-class
`httpRequest` fields whether or not you name them — spending slots on those
wastes them, and the adapter merges both sources. `sec-fetch-mode` and
`sec-fetch-site` are the two cut from the default list.

So when a dev asks to log an eleventh header, the answer is which one they are
dropping — not a config change.

The values land under `jsonPayload.loggingHttpRequestHeaders` as an **array of
pairs, base64-encoded**. That encoding is a feature: Web Bot Auth signatures
survive byte-for-byte, quotes and embedded colons included. An absent header is
simply missing from the array — there is no empty-string placeholder, so "not
sent" and "sent empty" are indistinguishable.

## Symptom → cause → fix

| symptom | almost certainly | what to do |
|---|---|---|
| Events arrive with no headers to classify on, `terraform plan` says "No changes" | **the allow-list was silently wiped by a destroy-time provisioner during a replacement** | this is the worst trap in the repo. The fix is already in place as two resources: `terraform_data.request_logging` triggers on `timestamp()` so every apply re-installs the list and drift heals itself, and `terraform_data.request_logging_cleanup` has triggers that never change so it fires only on a genuine destroy. **Do not "clean up" that noisy every-apply change** — it is the deliberate trade. |
| Headerless events for a few minutes after an apply | config propagation to the edge | wait. Measured: headerless at ~60s, all headers present at ~10 minutes. Treat a run of headerless events straight after a deploy as propagation, not breakage. |
| `gcloud logging read` returns nothing for the load balancer | `exclude_from_default_bucket` is working | that is the intended saving — entries are routed but never stored. **Pub/Sub is the only place to read raw entries.** `make sample` reads storage, so it goes quiet once the exclusion lands; pull the verify subscription instead. |
| The sink exists but publishes nothing | the writer identity lacks publisher on the topic | needs `roles/pubsub.admin` at apply time (`pubsub.editor` is not enough). Fallback in `PERMISSIONS.md`: grant the writer identity `roles/pubsub.publisher` at project level. |
| `terraform apply` fails at the sink | `roles/logging.configWriter` missing | see the roles table. Editor does not imply it. |
| Duplicate events in Obsero | delivery is at-least-once | a push that fails after the adapter already forwarded some events is retried whole. After `max_delivery_attempts` the message parks on the dead-letter topic, queued and replayable. |
| `terraform apply` wants to rebuild the image every run | it should not — the tag is a hash of the site sources | a no-op apply is genuinely a no-op. If it rebuilds every time, something is changing `server.mjs`, `Dockerfile` or `public/`. |
| Image build fails | Cloud Build's default compute service account cannot read its own staging bucket in a default-configured project | that is why the build is local. Needs `docker` and a configured credential helper. Set `adapter_image` to skip the build entirely. |
| `terraform destroy` prompts for `project_id` | it has no default | keep it in `site/terraform/terraform.tfvars`. `destroy.sh` checks for it up front rather than stalling. |
| A load balancer piece survives the destroy | partial destroy, or lost state | `../destroy.sh gcp --check` finds them in dependency order; `--sweep` deletes them. Service account IDs cap at 30 chars so the module truncates the prefix to 21 — a name-prefix match on the full prefix misses them. |
| An external LB cannot be created at all | org policy | only project-level IAM is visible locally; org constraints surface at apply time. The other likely one is `constraints/iam.disableServiceAccountKeyCreation`. |
| `sec-fetch-mode` is `cors` in a traffic run | Node's `fetch` overrides it | harness artefact only. It is also one of the two headers cut from the allow-list, partly for this reason. |

## Verifying it actually works

```bash
make headers   # the allow-list the LB is currently logging
make sample    # newest raw log entry (goes quiet once _Default is excluded)
make logs      # recent adapter output
make check     # score the last traffic run
make failures  # peek at the dead-letter topic
```

`make check` pulls entries from the verify subscription, replays them through
the **real** adapter parser, correlates the `?mt=<runId>-<seq>` tag on every
request, and diffs headers sent against received. Baseline: 40/40 correlated,
zero header loss, signature headers and full client-hint sets byte-for-byte
intact.

The demo site sets `debug_log_events = true`. Turn it off for anything real.

## Changing the adapter

Rewrite parts 2 and 3, leave part 1 alone, then:

```bash
make test
```

Fixtures are in `test/adapter.test.mjs`. Note that Pub/Sub push carries exactly
one log entry per delivery; the adapter still handles a batch because that
behaviour is not contractual.

## Cost and teardown

The pipeline is under $1/month per 1M requests. **The load balancer is not free
— roughly $18/month for the forwarding rule plus per-GB processing, whatever the
traffic.** That is irrelevant to a customer who already runs one and is the
single largest cost in this repo for a demo rig that exists only to make
traffic.

```bash
../setup.sh gcp destroy   # or: make destroy
make leftovers            # report what is still deployed, delete nothing
```

Do this between runs. Confirm current forwarding-rule and data-processing
pricing before quoting any of these numbers to anyone.

## Still unverified — do not assert these

- per-header value truncation in `loggingHttpRequestHeaders` (the *count* limit
  is settled at 10)
- whether request logging is sampled independently of `sample_rate` under load,
  the way CloudFront real-time logs turned out to be best-effort. Three runs of
  40 delivered 39, 40 and 40 — no evidence of loss, far too small a sample to
  call it exact.
- end-to-end latency beyond the observed ~30–60s
