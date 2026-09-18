# ingestion/ — the Terraform module

Streams CloudFront HTTP requests to Obsero. Reference for inputs, outputs and
day-2 operations; see [../README.md](../README.md) to get started and
[../NOTES.md](../NOTES.md) for measured behaviour.

```
standard (default, pay-as-you-go):
  viewer -> CloudFront --standard logging v2--> Firehose -> adapter -> Obsero

realtime (full headers, ~$11/mo):
  viewer -> CloudFront --real-time logs--> Kinesis -> Firehose -> adapter -> Obsero

                                    undeliverable batches -> S3 backup
```

## Install

```hcl
module "obsero_ingestion" {
  source = "./ingestion" # or github.com/obsero/aws-ingestion//ingestion?ref=v1

  name_prefix      = "acme-prod"
  site_token       = var.obsero_site_token
  log_source        = "standard"
  distribution_arns = [aws_cloudfront_distribution.site.arn]
}
```

For `realtime`, drop `distribution_arns` and attach
`module.obsero_ingestion.realtime_log_config_arn` to each cache behaviour you
want logged. `examples/` has both shapes. The module never modifies your
distribution either way.

## What Obsero receives

One JSON POST per request, with `x-obsero-domain` and `x-obsero-key` headers:

```json
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

In `realtime` mode the full viewer header set survives intact, Web Bot Auth
signatures and client hints included — that is what makes classification
possible downstream. `standard` mode carries only User-Agent, Referer, Host and
X-Forwarded-For, because CloudFront exposes nothing else there.

## Inputs

**Required**

| Name | Notes |
|---|---|
| `name_prefix` | Prefix for every resource. Unique per account/region. |
| `site_token` | Sent as `x-obsero-key`. Mark it sensitive. |

**Choosing a log source**

| Name | Default | Notes |
|---|---|---|
| `log_source` | `standard` | `standard` or `realtime`. |
| `distribution_arns` | `[]` | Distributions to collect from in `standard` mode. Empty is valid: the pipeline exists, idle, until you connect one. Ignored for `realtime`. |
| `existing_delivery_sources` | `{}` | Distribution ARN -> name of a standard logging v2 source it already has (e.g. one the CloudFront console made). Only one source is allowed per distribution, so the module adds a delivery from that one instead. |
| `distribution_arn` | `null` | Deprecated single-ARN form, merged into `distribution_arns`. |
| `ingest_url` | staging `/v1/events` | Must be https. |
| `sampling_rate` | `100` | Percent of requests logged. |

**Privacy**

| Name | Default | Notes |
|---|---|---|
| `excluded_headers` | `authorization, cookie, set-cookie` | Stripped before an event leaves your account. |
| `skipped_paths` | `/health, /favicon.ico` | Exact paths, never forwarded. |

**Rarely touched**

| Name | Default | Notes |
|---|---|---|
| `buffering_interval` | `60` | Seconds. 60 is the Firehose floor. |
| `buffering_size` | `1` | MB, whichever limit is hit first. |
| `retry_duration` | `300` | Seconds before a batch goes to the backup bucket. |
| `kinesis_shard_count` | `1` | `realtime` only. ~1000 records/sec per shard. |
| `kinesis_retention_hours` | `24` | How long records stay replayable. |
| `log_retention_days` | `14` | CloudWatch retention. |
| `backup_retention_days` | `30` | Backup bucket lifecycle. |
| `backup_force_destroy` | `false` | Let `terraform destroy` delete the backup bucket while it still holds undelivered batches. Off by default so a destroy stops rather than discarding them. |
| `forward_concurrency` | `8` | Parallel POSTs per batch. |
| `log_fields` | 20 fields | `realtime` only. Must include `cs-uri-stem`, `cs-method`, `sc-status`, `cs-headers`. |
| `standard_log_fields` | 17 fields | `standard` only. |
| `debug_log_events` | `false` | Log every forwarded event. Multiplies log volume by request rate. |
| `tags` | `{}` | Merged onto taggable resources. |

Bad configurations fail at plan time rather than shipping empty events — a
`existing_delivery_sources` key missing from `distribution_arns`, or a `log_fields` list without `cs-headers`, is a
precondition error.

## Outputs

`realtime_log_config_arn` (the one you attach), `log_source`, `connected_distributions`,
`kinesis_stream_name`, `kinesis_stream_arn`, `firehose_stream_name`,
`firehose_stream_arn`, `adapter_function_name`, `adapter_log_group`,
`backup_bucket`, `log_fields_in_order`.

## Operating it

```bash
aws logs tail <adapter_log_group> --follow        # forwarding, live
aws s3 ls s3://<backup_bucket>/ --recursive       # anything undeliverable
```

`batch_forwarded {count}` per Firehose batch; `forward_non_ok` or
`forward_failed` name the failure. Delivery is at-least-once and CloudFront's
own delivery is best-effort — both are quantified in [../NOTES.md](../NOTES.md).
