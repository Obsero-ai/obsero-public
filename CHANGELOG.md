# Changelog

All notable changes to this project are documented here.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

Because this repo is reference infrastructure you deploy yourself, "upgrading"
means pulling `main` and re-running `terraform apply`. Entries that require you
to re-apply, or that change the event payload, are called out as **Breaking**.

## [Unreleased]

## [0.1.0] — 2026-09-11

First public release.

### Added

- `obsero.mjs` — the event contract in one dependency-free file:
  `buildEvent`, `validateEvent`, `sendEvent`, plus a CLI to POST a test event
  and verify a site token.
- **AWS reference implementation** (`aws/`) — CloudFront to Firehose to a
  Lambda adapter. Two log sources: standard logs (User-Agent only) and realtime
  logs (full headers).
- **GCP reference implementation** (`gcp/`) — load balancer request logs to
  Pub/Sub to a Cloud Run adapter, with named headers on the cheap path.
- `setup.sh` — interactive installer that preflights the machine, deploys a
  demo site, creates the pipeline, and can send scored mock traffic.
- `destroy.sh` — teardown plus a sweep for resources Terraform lost track of,
  with `--check`, `--dry-run`, and `--sweep`.
- Traffic harness per cloud — 19 client personas, then scores what actually
  arrived at Obsero.
- `AGENTS.md` at the root and per cloud, for coding agents.
- Documentation site in `docs/`, published to GitHub Pages.

### Security

- Both adapters strip `authorization`, `cookie`, and `set-cookie` before any
  data leaves your account; covered by tests in both clouds.
- Header values that decode to a newline cannot forge an additional header —
  regression-tested in `aws/test/adapter.test.mjs`.
- Site tokens are written to a gitignored, `chmod 600` `terraform.tfvars`;
  Terraform state files are gitignored because they hold the token in cleartext.

[Unreleased]: https://github.com/Obsero-ai/obsero-public/compare/v0.1.0...HEAD
[0.1.0]: https://github.com/Obsero-ai/obsero-public/releases/tag/v0.1.0
