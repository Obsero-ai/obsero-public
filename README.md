# Obsero ingestion — reference implementations

[![CI](https://github.com/Obsero-ai/obsero-public/actions/workflows/ci.yml/badge.svg)](https://github.com/Obsero-ai/obsero-public/actions/workflows/ci.yml)
[![Docs](https://github.com/Obsero-ai/obsero-public/actions/workflows/pages.yml/badge.svg)](https://github.com/Obsero-ai/obsero-public/actions/workflows/pages.yml)
[![License: Apache 2.0](https://img.shields.io/badge/license-Apache--2.0-blue.svg)](LICENSE)
[![Terraform](https://img.shields.io/badge/terraform-%E2%89%A5%201.5-purple.svg)](https://developer.hashicorp.com/terraform/install)
[![Node](https://img.shields.io/badge/node-%E2%89%A5%2020-green.svg)](https://nodejs.org/)

Stream every HTTP request hitting your CDN to Obsero, so AI agent traffic can
be classified on the request headers.

This repo is a **starting point, not a product**. Two working end-to-end
implementations — AWS CloudFront and Google Cloud — plus a demo site and a
traffic harness for each. Fork it, keep the parts that match your stack, throw
away the rest.

Browsable docs: **[obsero-ai.github.io/obsero-public](https://obsero-ai.github.io/obsero-public/)**
— the same material as this README, plus a troubleshooting index. Source in
[`docs/`](docs/).

## The only thing you have to get right

Obsero cares about **two** things: the URL you POST to, and the payload. That's
the contract. Everything else — cloud, log source, language, batching, whether
you use Terraform at all — is your call.

```
POST https://analytics-staging.obsero.ai/v1/events

content-type:     application/json
x-obsero-domain:  acme.com          # which site this event belongs to
x-obsero-key:     <your site token> # proves you own it

{
  "path": "/pricing",
  "method": "GET",
  "statusCode": 200,
  "headers": {
    "host": "acme.com",
    "user-agent": "Mozilla/5.0 ...; compatible; ChatGPT-User/1.0; +https://openai.com/bot",
    "accept": "*/*",
    "signature-agent": "\"https://chatgpt.com\"",
    "signature-input": "sig1=(\"@authority\" \"signature-agent\");created=...",
    "signature": "sig1=:...:"
  }
}
```

One event per HTTP request.

| field | rules |
|---|---|
| `path` | Path **only**. `/pricing`, never `/pricing?ref=x` and never a full URL. Leaving the query string on makes every distinct URL its own page in the analytics — the most common mistake by far. |
| `method` | Uppercase. `"GET"`. |
| `statusCode` | A number, not a string. `200`. |
| `headers` | Lowercase names → verbatim values. This is what classification runs on, so send as many as you can get. |

**Headers worth carrying**, roughly in order of value:

```
user-agent                                       everything starts here
from                                             GPTBot, Googlebot
signature-agent, signature-input, signature      Web Bot Auth -- proves an agent
                                                 is who it claims to be
accept, accept-language                          browsers vs */* bots
sec-ch-ua, sec-ch-ua-platform, sec-ch-ua-mobile  client hints -- browsers only
sec-fetch-dest, sec-fetch-mode, sec-fetch-site   presence alone is the signal
```

Never forward `authorization`, `cookie` or `set-cookie`. Both adapters strip
them before anything leaves your account; keep that behaviour if you rewrite
one.

## Try it in 30 seconds

[`obsero.mjs`](obsero.mjs) is the whole contract in one dependency-free file —
`buildEvent`, `sendEvent`, `validateEvent`, about 100 lines. Run it to send a
test event and confirm your token works before you deploy anything:

```bash
node obsero.mjs --token <site-token> --domain acme.com
```

Then, in your own code, this is genuinely all it takes:

```js
import { buildEvent, sendEvent } from "./obsero.mjs";

await sendEvent(
  buildEvent({ path: req.url, method: req.method, statusCode: res.statusCode, headers: req.headers }),
  { token: process.env.OBSERO_SITE_TOKEN, domain: "acme.com" },
);
```

If you can call that from your edge middleware, your origin server or your log
processor, you are done — you do not need anything else in this repo.

## Or watch it work end to end

One command. It checks your machine first and tells you what is missing before
it creates anything.

```bash
./setup.sh
```

```
Obsero ingestion -- aws

  1) Deploy the mock site          a site worth collecting logs from
  2) Deploy the ingestion pipeline asks for your tracking ID
  3) Connect                       pick distributions already in your account
  4) Destroy everything            the rig bills while it is up

  5) Send mock traffic and score what arrived
  6) Status -- what is deployed right now
  7) Switch cloud
```

**Step 1** puts a static site behind a real CDN, so there is traffic worth
logging, and prints the URL. Nothing reaches Obsero yet. Skip it if you only
want to collect from a site you already run.

**Step 2** asks for your tracking ID, offers to POST one test event to prove the
ID is accepted, and then builds the pipeline on its own -- on AWS it does not
need the mock site and starts out collecting from nothing. The ID is saved to
`<cloud>/site/terraform/terraform.tfvars` (gitignored, `chmod 600`) because
`terraform destroy` and every later apply need it too.

**Step 3** (AWS) lists every CloudFront distribution in your account -- the mock
site and anything you already run -- and lets you tick the ones to collect
from. It never modifies a distribution: it adds a standard logging v2 delivery
from each one into the pipeline's Firehose, and untick removes it again. If a
distribution already has a standard logging v2 source (the CloudFront console
creates one), that source is reused rather than replaced. On GCP the pipeline
attaches to the mock site in step 2, so there is no step 3.

**Step 4** calls `./destroy.sh`.

Every item has a flag form, for CI or for scripting:

```bash
./setup.sh aws site
./setup.sh aws pipeline --token <tracking-id>
./setup.sh aws connect --dist E2ABC123,E3DEF456   # exactly these; --dist none clears
./setup.sh aws connect --dist +E2ABC123           # add one to what is connected
./setup.sh aws traffic -n 40
./setup.sh aws status
./setup.sh aws destroy --yes
```

The site, the pipeline and the connections are **one Terraform stack**; steps
1-3 are targeted applies of their part of it, and step 3 records your picks as
`connected_distribution_arns` in `terraform.tfvars`. `make deploy` in either
cloud directory builds the site and the pipeline and connects the two, and
`make` alone lists every other task.

## What's here

```
obsero.mjs      the contract: build an event, validate it, POST it
setup.sh        the interactive installer
destroy.sh      teardown, plus a sweep for resources Terraform lost track of
aws/            CloudFront -> Firehose -> Lambda adapter -> Obsero
gcp/            Load balancer logs -> Pub/Sub -> Cloud Run adapter -> Obsero
docs/           the GitHub Pages site (`python3 docs/build.py` after editing)
```

Each cloud directory has the same three parts:

```
ingestion/      the Terraform module you would actually ship
site/           a demo site to point it at, so you can see traffic flow
test/           a traffic harness: 19 client personas, then score what arrived
```

Both `ingestion/` modules deploy on their own. `site/` and `test/` exist to
prove the thing works and are the first things to delete once it does.

## Which one do I want?

| your setup | start here | why |
|---|---|---|
| CloudFront in front of anything | [`aws/`](aws/) | Two log sources: cheap (User-Agent only) or full headers for ~$11/mo. |
| Google Cloud load balancer + Cloud CDN | [`gcp/`](gcp/) | Full headers on the cheap path — no trade to make. |
| A **plain GCS bucket** behind Cloud CDN | [`gcp/`](gcp/), read the caveat first | Backend *buckets* emit no request logs at all. Your origin has to be a backend *service* (Cloud Run, GKE, a MIG). |
| Cloudflare, Fastly, Akamai, a bare origin | none of them | Read `obsero.mjs`, call `sendEvent` from wherever you already see requests. That is the entire integration. |

## Adapting this to your own stack

Both adapters have the same shape, and the top of each file is the part you
keep:

- [`aws/ingestion/lambda/adapter/index.mjs`](aws/ingestion/lambda/adapter/index.mjs)
- [`gcp/ingestion/adapter/index.mjs`](gcp/ingestion/adapter/index.mjs)

```
1. unwrap whatever the cloud delivers   <- cloud-specific, rewrite freely
2. turn each log line into an event     <- cloud-specific, rewrite freely
3. build the payload and POST it        <- the contract, keep this
```

Change step 1 and 2 to match your log source. Leave step 3 alone. Then:

```bash
cd aws && make test     # no cloud account needed
```

`make test` runs the real adapter parser over sample log lines and checks the
resulting payload against `validateEvent`. If it passes, Obsero will accept
what you produce.

## Tearing it down

The demo sites cost real money to leave running — the GCP load balancer bills
about $18/month whether or not any traffic hits it.

```bash
./destroy.sh              # both clouds, after confirming
./destroy.sh aws          # one cloud
./destroy.sh --check      # just tell me what is still deployed
./destroy.sh --dry-run    # show the destroy plan, touch nothing
```

Terraform does the work; the script handles what it cannot. It empties the S3
buckets first (Terraform refuses to delete a bucket holding objects it did not
create, which is exactly what the backup bucket is for), passes each stack the
credentials it needs, and then **checks the cloud afterwards** for anything
still standing — a lost state file or a half-finished destroy leaves resources
that no `terraform plan` will ever mention.

Leftovers are reported with the exact command to remove each one. Add `--sweep`
to have the script run those commands itself. It matches on the resource name
prefix, so pass `--prefix` if you renamed things.

```bash
./destroy.sh --sweep      # delete leftovers too, not just report them
```

CloudFront is the one exception: a distribution has to be disabled, left to
propagate, and deleted minutes later, so the script reports it rather than
pretending it can be done in one pass.

## If you work with a coding agent

[`AGENTS.md`](AGENTS.md) at the root, plus [`aws/AGENTS.md`](aws/AGENTS.md) and
[`gcp/AGENTS.md`](gcp/AGENTS.md). They carry the contract, the order to check
things in when a setup is stuck, a symptom-to-fix table per cloud, and the
handful of things in the Terraform that must not be "cleaned up" because
removing them fails silently. Point your agent at them before it touches
anything.

## Getting a site token

Ask Obsero for one, then keep it out of the repo — both `site/terraform/`
directories read it from a gitignored `terraform.tfvars`:

```hcl
obsero_site_token = "..."
```

## Contributing

Bug reports, gotchas you hit, and new log sources are all welcome — see
[CONTRIBUTING.md](CONTRIBUTING.md) for the setup, the five rules that matter,
and the checks CI runs. For anything beyond a typo, open an issue first.

This project follows the [Contributor Covenant](CODE_OF_CONDUCT.md).

## Security

Found a vulnerability? **Do not open a public issue** — use
[private reporting](https://github.com/Obsero-ai/obsero-public/security/advisories/new)
or email security@obsero.ai. See [SECURITY.md](SECURITY.md) for scope and what
to expect.

## License

[Apache License 2.0](LICENSE). Copyright 2026 Obsero.

You may use, modify, and redistribute this in your own products, including
commercially. Keep the notices; the license includes an express patent grant.
