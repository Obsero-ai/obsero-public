# AGENTS.md

Instructions for an AI agent working in this repo. Read this before running
anything. The per-cloud detail is in [`aws/AGENTS.md`](aws/AGENTS.md) and
[`gcp/AGENTS.md`](gcp/AGENTS.md) — open the one the dev is actually using.

## What this repo is

Two working reference implementations that stream every HTTP request hitting a
CDN to Obsero, so AI-agent traffic can be classified on request headers.

```
obsero.mjs   the contract: build an event, validate it, POST it   (~150 lines)
setup.sh     the interactive installer devs run
destroy.sh   teardown + a sweep for resources Terraform lost track of
aws/         CloudFront -> Firehose -> Lambda adapter -> Obsero
gcp/         LB request logs -> Pub/Sub -> Cloud Run adapter -> Obsero
docs/        the GitHub Pages site (edit these when behaviour changes)
```

It is a starting point, not a product. Devs are expected to fork it, keep the
adapter, and throw away `site/` and `test/`.

## The contract — the one thing you must not break

Everything else in the repo is negotiable. This is not:

```
POST https://analytics-staging.obsero.ai/v1/events
content-type:    application/json
x-obsero-domain: acme.com           # which site the event belongs to
x-obsero-key:    <site token>       # a.k.a. the tracking ID

{ "path": "/pricing", "method": "GET", "statusCode": 200, "headers": { ... } }
```

| field | rule | why it matters |
|---|---|---|
| `path` | path only — no query string, no origin | a query string makes every distinct URL its own page in the analytics. The single most common mistake. |
| `method` | uppercase string | |
| `statusCode` | number, not string | |
| `headers` | lowercase names, verbatim values | this is what classification runs on |

`authorization`, `cookie` and `set-cookie` are **never** forwarded. Both
adapters strip them before anything leaves the customer's account. If you
rewrite an adapter, keep that.

`validateEvent()` in `obsero.mjs` is the machine-checkable form of all of the
above. Each cloud's `make test` runs the real adapter parser over sample log
lines and asserts the result against it — no cloud account needed, so there is
never an excuse for not running it.

## Both adapters have the same three-part shape

`aws/ingestion/lambda/adapter/index.mjs` and `gcp/ingestion/adapter/index.mjs`:

```
1. THE CONTRACT     build the payload and POST it     <- keep this
2. LOG PARSING      log line/entry -> event           <- cloud-specific, rewrite freely
3. TRANSPORT        unwrap the batch, ack it          <- cloud-specific, rewrite freely
```

When a dev asks "how do I use this with Cloudflare / Fastly / my origin
server?", the answer is **not** to port a cloud directory. It is: import
`buildEvent` and `sendEvent` from `obsero.mjs`, call them from wherever they
already see requests, done. Say that plainly rather than building infrastructure
they do not need.

## Helping a dev set up

`./setup.sh` is the path. It is one Terraform stack per cloud, applied in
parts, and the menu mirrors that:

```
1) Deploy the mock site           targeted apply -- site only, no Obsero involved
2) Deploy the ingestion pipeline  prompts for the tracking ID; on AWS a targeted
                                  apply of module.ingestion, built idle
3) Connect (AWS only)             pick CloudFront distributions in the account;
                                  writes connected_distribution_arns, re-applies
4) Destroy everything             calls ./destroy.sh
5) Send mock traffic and score it
6) Status
```

Non-interactive equivalents, useful when you are driving it yourself:

```bash
./setup.sh aws site
./setup.sh aws pipeline --token <tracking-id>
./setup.sh aws connect --dist <id>[,<id>]   # exact set; "none" clears, "+<id>" adds
./setup.sh aws traffic -n 40
./setup.sh aws status
./setup.sh aws destroy --yes
```

Connecting never modifies a distribution: it adds a standard logging v2
delivery into the pipeline's Firehose. A distribution that already has a
standard logging v2 source keeps it; step 3 records it in
`existing_delivery_sources` and the module adds a delivery from it instead of
creating a second source, which CloudWatch Logs refuses.

The tracking ID is persisted to `<cloud>/site/terraform/terraform.tfvars`
(gitignored, chmod 600) because `terraform destroy` and every later apply need
it too. Step 1 writes the placeholder `set-in-step-2` there; step 2 refuses to
apply while that is still the value.

### Order of operations when a dev is stuck

Work down this list. Do not skip to Terraform.

1. `cd <cloud> && make test` — does the adapter still produce a valid payload?
   Needs no cloud account. If this fails, nothing downstream matters.
2. `./setup.sh <cloud> status` — what is actually deployed, including resources
   that fell out of Terraform state.
3. `node obsero.mjs --token <id> --domain <host>` — is the tracking ID accepted?
   A rejected token means the pipeline forwards into nothing, silently.
4. `make -C <cloud> logs` — is the adapter being invoked, and what does it say?
5. Only then read the per-cloud `AGENTS.md` symptom table.

## Rules

- **Never run `terraform apply` or `destroy` without the dev's explicit go-ahead
  on that specific command.** These stacks cost real money and the GCP
  forwarding rule bills at idle (~$18/month).
- **Never commit a token.** `terraform.tfvars` is gitignored in both stacks;
  keep it that way. If you find a token in a tracked file, say so immediately.
- **Never remove the header allow-list re-assert in `gcp/ingestion`** — see
  `gcp/AGENTS.md`. Removing it fails silently and `terraform plan` reports
  nothing wrong.
- **Never remove the `LogDeliveryEnabled` tag in `aws/ingestion`** — without it
  CloudFront delivers nothing, with no error anywhere.
- Wait out the documented latency before declaring something broken: AWS has a
  60–90s floor, GCP's header allow-list takes minutes to reach the edge.
- `NOTES.md` in each cloud directory records behaviour measured on live
  deployments. Trust it over your priors about how these services behave, and
  add to it when you measure something new.

## Where the docs live

`docs/` is a static site served by GitHub Pages from the `docs/` folder — no
Jekyll, no framework, `.nojekyll` is present. Enable it under
**Settings → Pages → Deploy from branch → `/docs`**.

Edit the prose **directly in `docs/*.html`** — the page body is everything
between the breadcrumb `<nav>` and the "Was this page helpful?" block. Then
**always run the build**, from the repo root:

```bash
python3 docs/build.py
```

It re-derives the left nav, the "On this page" TOC, heading anchors,
breadcrumbs, prev/next links and `assets/search-index.js` from that prose. The
search index carries the full text of every section, so a term that appears only
in body copy is still findable — which also means **an edit without a rebuild
leaves the search index stale**. It is idempotent (running it twice is
byte-identical), standard library only, and safe to run whenever you are unsure.

When you change behaviour that a dev depends on, update the matching page:

| change | also edit |
|---|---|
| the payload or its headers | `docs/contract.html` |
| `setup.sh` flow or flags | `docs/quickstart.html` |
| AWS pipeline or cost | `docs/aws.html` |
| GCP pipeline, permissions or cost | `docs/gcp.html` |
| a new failure mode you diagnosed | `docs/troubleshooting.html` **and** the cloud's `NOTES.md` |

`docs/assets/docs.css` and `docs/assets/docs.js` are the chrome: theme tokens
(light and dark), the nav drawer, code-block copy buttons, the sidebar search
and the TOC scrollspy. Every one of those degrades to plain working HTML if the
JavaScript never runs, so keep it that way.
