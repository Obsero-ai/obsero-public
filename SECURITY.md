# Security policy

## Reporting a vulnerability

**Do not open a public issue for a security problem.**

Report it privately through GitHub:
[**Report a vulnerability**](https://github.com/Obsero-ai/obsero-public/security/advisories/new)
— this opens a private advisory visible only to you and the maintainers.

If you cannot use GitHub advisories, email **security@obsero.ai**.

Please include the affected file or cloud, what an attacker gains, and the
smallest reproduction you have. A log line or a `terraform plan` excerpt is
usually enough.

### What to expect

| | |
|---|---|
| First response | within 3 business days |
| Triage decision | within 10 business days |
| Fix or mitigation | severity-dependent; we will tell you the target date |

We will credit you in the advisory unless you ask us not to. We do not run a
paid bug bounty for this repository.

## Scope

This repo is **reference infrastructure you deploy into your own cloud
account**. It holds no running service of ours, so the interesting
vulnerabilities are the ones that would leak your data or widen your blast
radius.

**In scope**

- Anything that causes a secret — a site token, a cloud credential — to be
  logged, committed, or sent anywhere other than the Obsero ingest URL.
- Anything that forwards a request header the adapters are supposed to strip
  (`authorization`, `cookie`, `set-cookie`).
- Header or log-line injection: a crafted request that forges a field in the
  event payload.
- Terraform that grants materially more IAM permission than the documented
  least privilege, or that leaves a bucket, topic, or endpoint publicly
  readable when it should not be.

**Out of scope**

- The Obsero SaaS at `obsero.ai` and `analytics.obsero.ai`. Report those to
  security@obsero.ai directly; this repo only POSTs to them.
- Cost. Leaving the demo rig running bills you real money — that is documented
  behaviour, not a vulnerability. See "Tearing it down" in the README.
- Vulnerabilities in AWS, Google Cloud, or Terraform providers themselves.
  Report upstream; tell us if this repo's defaults make them worse.
- The `site/` and `test/` directories. They are a deliberately plain demo site
  and a traffic generator, not production code, and the README says to delete
  them once the pipeline works.

## Supported versions

`main` is the only supported branch. Fixes land there; there are no backports.
Because you deploy this yourself, "upgrading" means pulling `main` and
re-running `terraform apply`.

## Handling secrets in this repo

A site token is a credential. The setup script writes it to
`<cloud>/site/terraform/terraform.tfvars`, which is gitignored and
`chmod 600`. Terraform state also contains it in cleartext — `*.tfstate` and
`*.tfstate.*` are gitignored for that reason.

Before you commit, confirm you are not adding either:

```bash
git status --porcelain           # tfvars and tfstate must not appear
git diff --cached | grep -iE 'obsero_site_token|x-obsero-key'
```

If you do leak a token, tell Obsero so it can be rotated. Deleting the commit
is not enough — assume anything pushed to a public repo is captured.
