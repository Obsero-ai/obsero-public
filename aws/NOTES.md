# AWS: measured behaviour and gotchas

Everything here was observed on a live deployment, not inferred from docs. It
is separated from the README because none of it is needed to *use* the module —
only to trust its numbers, or to hand-build the pipeline yourself.

## Delivery is best-effort at the CloudFront edge (realtime)

CloudFront delivers real-time logs on a best-effort basis: some requests are
never written to Kinesis at all. This is upstream of the whole pipeline, so no
setting here prevents it.

Measured across five runs (188 requests) at `sampling_rate = 100`: four runs
delivered 100%, one delivered 20 of 30. The lost records did not correlate with
status code, path, client, or latency, and the same request rate reproduced
cleanly on a later run. Kinesis `IncomingRecords` confirmed the records were
never sent, rather than lost downstream.

Treat the counts as a high-fidelity sample, not an exact ledger. Do not
reconcile them against origin logs or bill directly on them.

## Delivery is at-least-once

If any event in a Firehose batch fails to forward, the adapter fails the whole
batch so Firehose retries — which duplicates the events that already landed.
After `retry_duration` the batch goes to the backup bucket rather than being
dropped.

## Latency floor: 60–90s

CloudFront flushes real-time logs continuously, but Firehose buffers for at
least 60s. That is a floor, not a tuning knob.

## The LogDeliveryEnabled tag (standard mode)

Standard logging v2 writes through the `AWSServiceRoleForLogDelivery`
service-linked role, whose policy allows `firehose:PutRecordBatch` **only on
streams tagged `LogDeliveryEnabled = true`**:

```json
"Condition": { "StringEquals": { "aws:ResourceTag/LogDeliveryEnabled": "true" } }
```

Without the tag CloudFront delivers **nothing**, and there is no error
anywhere — the delivery reports healthy, the Firehose reports healthy, and
`IncomingRecords` simply stays at zero. The module applies the tag
automatically in standard mode. Worth knowing if you ever hand-build this.

## Two CloudFront parsing behaviours (realtime only)

Both are handled by the adapter. They are documented because they bite anyone
reading the raw Kinesis stream themselves. Standard mode is self-describing
JSON, so neither one applies there.

**1. Field order is not your field order.** CloudFront emits real-time log
fields in its own canonical order, ignoring the order in the log config.
Records are tab-separated with no header row, so a positional parser that
trusts the config order reads every column shifted. The module sorts
`log_fields` into canonical order and hands that same list to the adapter;
`log_fields_in_order` exports it.

**2. `cs-uri-stem` includes the query string** in real-time logs, unlike
standard access logs where it is path-only. The adapter strips it, or every
distinct query string would register as its own path in the analytics.

## Why the adapter Lambda exists at all

Firehose's HTTP endpoint destination cannot post to `/v1/events` directly:

- it wraps records in `{requestId, timestamp, records:[{data}]}`
- it sends the key as `X-Amz-Firehose-Access-Key`, and cannot send arbitrary
  headers such as `x-obsero-domain` / `x-obsero-key`
- it requires a specific JSON ack back, or treats the delivery as failed

The adapter unwraps the envelope, converts each log line into one Obsero event,
strips excluded headers, and returns the ack. Its Function URL is
unauthenticated at the AWS layer — Firehose cannot SigV4-sign to a Function
URL — so the shared Firehose access key is what the handler checks. The URL is
not secret, but is useless without that key.

## Concurrency footprint

The adapter uses **one concurrent Lambda execution per Kinesis shard**. Firehose
reads each shard serially and invokes once per buffer window, so at the default
`kinesis_shard_count = 1` the steady state is exactly 1 concurrent execution,
~1s per invocation, one invocation per minute. Measured, not estimated.

That matters on accounts with a low concurrency ceiling. New AWS accounts are
capped at **10 concurrent executions** account-wide, and at that ceiling
`reserved_concurrent_executions` cannot be set at all — AWS requires unreserved
concurrency to stay at or above 10, so any reservation is rejected. The adapter
therefore shares an unprotected pool with every other function in the account.

If another function saturates the pool, the Function URL returns 429, Firehose
treats it as a failed delivery, retries for `retry_duration`, and then writes
the batch to the backup bucket. Nothing is lost, but those events do not reach
Obsero until the backup is replayed. Watch `Throttles` on the adapter if you
share a small pool.

Concurrency scales with `kinesis_shard_count`, so raising shards for a busy
site raises the Lambda footprint roughly one-for-one.

## Cost

Lambda, CloudFront and S3 usage at this volume sit inside the AWS free tier.
Kinesis Data Streams does not have a free tier — one provisioned shard is about
**$11/month** ($0.015/shard-hour) and is `realtime` mode's floor cost, since
CloudFront real-time logs can only be delivered to Kinesis. Firehose adds
~$0.029/GB ingested, which is cents at typical volumes. In `standard` mode
there is no Kinesis stream and therefore no idle cost at all; Firehose only
reaches $11/month at roughly 380M requests.

## Harness caveat

Node's `fetch` overrides `sec-fetch-mode` to `cors` and adds
`connection: keep-alive`, so those two fields in a `make traffic` run do not
reflect a real browser. Every User-Agent and every other header passes through
untouched.
