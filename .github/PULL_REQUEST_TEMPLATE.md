## What this changes

<!-- One or two sentences. What breaks, or stays broken, without it? -->

## Why

<!-- Link the issue: "Closes #123". For a gotcha fix, describe the symptom you hit. -->

## How it was tested

<!-- Tick what you actually did. Unit tests only is fine — say so. Silence is not. -->

- [ ] `node --test aws/test/adapter.test.mjs`
- [ ] `node --test gcp/test/adapter.test.mjs`
- [ ] Deployed and verified against a real account — cloud: <!-- aws / gcp -->
- [ ] Docs only, no code paths touched

## Infrastructure changes

<!-- Delete this section if you touched no Terraform. Otherwise paste the
     relevant `terraform plan` output, trimmed to the interesting resources. -->

```
```

## Checklist

- [ ] I read [CONTRIBUTING.md](../CONTRIBUTING.md).
- [ ] No secrets: no `terraform.tfvars`, no `*.tfstate`, no site token in a diff or a log paste.
- [ ] The adapters still strip `authorization`, `cookie`, and `set-cookie`.
- [ ] `path` is still a path — no query string, no host.
- [ ] If I edited `docs/*.html`, I ran `python3 docs/build.py` and committed the result.
- [ ] If I removed anything from the Terraform, I checked it against `AGENTS.md` first.
