# Contributing

Thanks for helping. This repo is a **starting point, not a product** — the bar
for a change is "does this make the reference easier to adapt", not "does this
add a feature".

## What we are looking for

Most valuable, roughly in order:

- **A new log source or cloud.** Cloudflare, Fastly, Akamai, a bare origin.
  If you wired `sendEvent` into something we do not cover, that is the most
  useful PR you can send.
- **A gotcha you hit.** A symptom-to-fix row in `docs/troubleshooting.html`
  saves the next person hours. Small, welcome, no ceremony.
- **Corrections to the contract docs.** If the README or `docs/` describes
  behaviour that is no longer true, fixing it outranks new code.
- **Least-privilege fixes** to the Terraform.

What we will usually decline: extra abstraction, a plugin system, a dependency
added to `obsero.mjs` (it is deliberately dependency-free), or anything that
makes the demo site fancier.

## Before you start

For anything beyond a typo, **open an issue first**. This repo is intentionally
small and we would rather talk you out of work than reject a finished PR.

## Development setup

You need Node 20+ for the tests. Terraform 1.5+ and a cloud account are needed
only if you are changing infrastructure.

```bash
git clone https://github.com/Obsero-ai/obsero-public.git
cd obsero-public
cd aws && make test        # no cloud account needed
cd ../gcp && make test
```

There is nothing to install — the tests use Node's built-in runner and the repo
has no dependencies.

## The rules that matter

**1. The contract is load-bearing.** `obsero.mjs` defines the payload Obsero
accepts. Both adapters end by building that payload and POSTing it. You may
rewrite how a log line is parsed; do not change what comes out the other end
unless the change is the point of the PR.

**2. Never forward `authorization`, `cookie`, or `set-cookie`.** Both adapters
strip them before anything leaves your account. There is a test for this. Keep
it that way.

**3. `path` is a path.** No query string, no scheme, no host. This is the most
common integration bug and the tests guard it.

**4. Read `AGENTS.md` before touching Terraform.** It lists the resources and
arguments that must not be "cleaned up" — several of them fail *silently* when
removed, so the mistake surfaces days later as missing data.

**5. Never commit a token or state.** `terraform.tfvars` and `*.tfstate` are
gitignored. See [SECURITY.md](SECURITY.md).

## Checks

CI runs exactly these; run them locally and it will be green.

```bash
node --test aws/test/adapter.test.mjs   # adapter output vs. the contract
node --test gcp/test/adapter.test.mjs
terraform fmt -check -recursive aws gcp # formatting
python3 docs/build.py                   # must not change any file
bash -n setup.sh destroy.sh             # shell syntax
```

### Editing the docs

`docs/` is the GitHub Pages site. Edit the **prose directly** in `docs/*.html`
— everything between the breadcrumb `<nav>` and the "Was this page helpful?"
block — then regenerate the navigation, table of contents, and search index:

```bash
python3 docs/build.py
```

Commit the result. `build.py` is deterministic: running it twice produces
byte-identical files, and **CI fails if running it changes anything**, which is
how the published site is kept from drifting. Do not hand-edit the left nav, the
"On this page" list, or `assets/search-index.js` — they are generated.

## Pull requests

- Branch from `main`. One logical change per PR.
- Write a commit subject in the imperative mood, under ~72 characters:
  `aws: keep signature-agent header through the realtime path`.
- Say **what breaks without the change** in the description. For an infra
  change, paste the relevant `terraform plan` output.
- If you changed an adapter, say which cloud you actually deployed and tested
  against, or say that you only ran the unit tests. Both are acceptable —
  silence is not.

By contributing you agree your work is licensed under
[Apache License 2.0](LICENSE), and that you have the right to submit it.

## Code of conduct

This project follows the [Contributor Covenant](CODE_OF_CONDUCT.md).
