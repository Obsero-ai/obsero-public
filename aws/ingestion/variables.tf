variable "name_prefix" {
  description = "Prefix for every resource this module creates. Must be unique within the account and region."
  type        = string

  validation {
    condition     = can(regex("^[a-z0-9][a-z0-9-]{1,38}$", var.name_prefix))
    error_message = "name_prefix must be 2-39 lowercase alphanumeric or hyphen characters and start with alphanumeric."
  }
}

variable "log_source" {
  description = <<-EOT
    Where request logs come from.

      "standard" - CloudFront standard logging v2 delivered straight to Firehose.
                   Pay-as-you-go, no idle cost, but CloudFront only exposes
                   User-Agent, Referer, Cookie and Host. Requires distribution_arn.

      "realtime" - CloudFront real-time logs via a Kinesis Data Stream. Carries
                   the FULL viewer header set (cs-headers), including Web Bot Auth
                   signature headers, at a ~$11/month per-shard floor. Requires
                   attaching realtime_log_config_arn to your cache behaviour.

    Pick "realtime" if you classify on anything beyond User-Agent.
  EOT
  type        = string
  default     = "standard"

  validation {
    condition     = contains(["standard", "realtime"], var.log_source)
    error_message = "log_source must be \"standard\" or \"realtime\"."
  }
}

variable "distribution_arn" {
  description = "CloudFront distribution ARN to collect logs from. Required when log_source is \"standard\"; ignored for \"realtime\"."
  type        = string
  default     = null
}

variable "standard_log_fields" {
  description = "Fields requested from CloudFront standard logging v2. Only used when log_source is \"standard\"."
  type        = list(string)
  default = [
    "timestamp", "c-ip", "sc-status", "cs-method", "cs-uri-stem", "cs-uri-query",
    "x-host-header", "cs(Host)", "cs(User-Agent)", "cs(Referer)", "x-forwarded-for",
    "cs-protocol", "cs-protocol-version", "time-taken", "sc-content-type",
    "x-edge-result-type", "c-country",
  ]
}

variable "ingest_url" {
  description = "Analytics ingest endpoint. Receives one JSON event per HTTP request."
  type        = string
  default     = "https://analytics-staging.obsero.ai/v1/events"

  validation {
    condition     = startswith(var.ingest_url, "https://")
    error_message = "ingest_url must be https."
  }
}

variable "site_token" {
  description = "Sent as the x-obsero-key header on every forwarded event."
  type        = string
  sensitive   = true
}

variable "sampling_rate" {
  description = "Percentage of viewer requests CloudFront logs. 100 = every request."
  type        = number
  default     = 100

  validation {
    condition     = var.sampling_rate >= 1 && var.sampling_rate <= 100
    error_message = "sampling_rate must be between 1 and 100."
  }
}

variable "excluded_headers" {
  description = "Request headers stripped before an event leaves your account."
  type        = list(string)
  default     = ["authorization", "cookie", "set-cookie"]
}

variable "skipped_paths" {
  description = "Exact paths that are never forwarded."
  type        = list(string)
  default     = ["/health", "/favicon.ico"]
}

variable "buffering_interval" {
  description = "Seconds Firehose buffers before delivering. 60 is the floor; lower is not possible."
  type        = number
  default     = 60

  validation {
    condition     = var.buffering_interval >= 60 && var.buffering_interval <= 900
    error_message = "buffering_interval must be between 60 and 900 seconds."
  }
}

variable "buffering_size" {
  description = "MB Firehose buffers before delivering, whichever limit is hit first."
  type        = number
  default     = 1
}

variable "retry_duration" {
  description = "Seconds Firehose keeps retrying a failed batch before writing it to the backup bucket."
  type        = number
  default     = 300
}

variable "kinesis_shard_count" {
  description = "Shards on the log stream. One shard handles ~1000 records/sec; raise it for busy sites."
  type        = number
  default     = 1
}

variable "kinesis_retention_hours" {
  description = "How long records stay replayable in Kinesis."
  type        = number
  default     = 24
}

variable "log_retention_days" {
  description = "CloudWatch retention for the adapter and Firehose logs."
  type        = number
  default     = 14
}

variable "backup_retention_days" {
  description = "How long undeliverable batches are kept in the backup bucket."
  type        = number
  default     = 30
}

variable "backup_force_destroy" {
  description = "Let `terraform destroy` delete the backup bucket even when it still holds undelivered batches. Off by default: those are events that never reached Obsero, and emptying the bucket loses them for good. The demo site turns it on."
  type        = bool
  default     = false
}

variable "forward_concurrency" {
  description = "Parallel POSTs the adapter makes to the ingest endpoint per batch."
  type        = number
  default     = 8
}

variable "log_fields" {
  description = "CloudFront real-time log fields to capture. Only used when log_source is \"realtime\". Order is irrelevant; the module sorts them into CloudFront's canonical order."
  type        = list(string)
  default = [
    "timestamp", "c-ip", "sc-status", "cs-method", "cs-uri-stem", "cs-uri-query",
    "cs-host", "x-host-header", "cs-user-agent", "cs-referer", "x-forwarded-for",
    "cs-protocol", "cs-protocol-version", "time-taken", "sc-content-type",
    "x-edge-result-type", "c-country", "cs-headers", "cs-header-names",
    "cs-headers-count",
  ]
}

variable "debug_log_events" {
  description = "Log every forwarded event and one raw record per batch to CloudWatch. Useful when validating a new deployment; multiplies log volume by your request rate, so leave it off in steady state."
  type        = bool
  default     = false
}

variable "tags" {
  description = "Extra tags applied to taggable resources."
  type        = map(string)
  default     = {}
}
