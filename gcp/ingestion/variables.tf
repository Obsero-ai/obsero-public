variable "project_id" {
  description = "Project holding the backend service and the pipeline."
  type        = string
}

variable "region" {
  description = "Region for the Cloud Run adapter and its image repository."
  type        = string
  default     = "us-central1"
}

variable "name_prefix" {
  description = "Prefix for every resource this module creates. Must be unique within the project."
  type        = string

  validation {
    condition     = can(regex("^[a-z0-9][a-z0-9-]{1,38}$", var.name_prefix))
    error_message = "name_prefix must be 2-39 lowercase alphanumeric or hyphen characters and start with alphanumeric."
  }
}

variable "backend_service_name" {
  description = <<-EOT
    Global backend service whose request logs should be shipped. The module
    enables logging on it and installs the request-header allow-list.

    It must be a backend SERVICE. A backend BUCKET has no logConfig field in
    the Compute API, so a Cloud Storage origin behind Cloud CDN produces no
    request logs and cannot be onboarded without changing its origin.
  EOT
  type        = string
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

variable "logged_headers" {
  description = <<-EOT
    Request headers the load balancer writes into Cloud Logging.

    This is the headline difference from AWS. CloudFront standard logging
    carries only User-Agent, Referer, Cookie and Host; the full viewer header
    set costs ~$11/month for a Kinesis shard. GCP has no such trade -- name the
    headers you classify on and they arrive through the cheap path.

    Capped at 10 by the Compute API. Budget them carefully: user-agent, referer
    and the client IP are reported as first-class httpRequest fields whether or
    not you ask for them, so listing those here would waste slots.

    It is an explicit allow-list, not "all headers", which is arguably better:
    the payload carries only what classification needs, so nothing incidental
    leaves the project.
  EOT
  type        = list(string)
  default = [
    "from",                                                # GPTBot, Googlebot
    "signature-agent", "signature-input", "signature",     # Web Bot Auth
    "accept", "accept-language",                           # browsers vs */* bots
    "sec-ch-ua", "sec-ch-ua-platform", "sec-ch-ua-mobile", # client hints
    "sec-fetch-dest",                                      # presence alone is the signal
  ]

  validation {
    condition     = length(var.logged_headers) <= 10
    error_message = "At most 10 headers can be logged per backend service. The Compute API rejects an eleventh: \"At most 10 logging_http_request_headers can be specified per BackendService.\""
  }

  validation {
    condition     = length(var.logged_headers) == length(distinct([for h in var.logged_headers : lower(h)]))
    error_message = "logged_headers contains duplicates, which waste slots against the limit of 10."
  }
}

variable "sample_rate" {
  description = "Fraction of requests the load balancer logs. 1.0 = every request."
  type        = number
  default     = 1.0

  validation {
    condition     = var.sample_rate > 0 && var.sample_rate <= 1
    error_message = "sample_rate must be greater than 0 and at most 1.0."
  }
}

variable "excluded_headers" {
  description = "Request headers stripped before an event leaves the project."
  type        = list(string)
  default     = ["authorization", "cookie", "set-cookie"]
}

variable "skipped_paths" {
  description = "Exact paths that are never forwarded."
  type        = list(string)
  default     = ["/health", "/favicon.ico"]
}

variable "adapter_image" {
  description = "Prebuilt adapter image. Leave null to build and push adapter/ locally, which needs docker and gcloud on the machine running apply."
  type        = string
  default     = null
}

variable "max_delivery_attempts" {
  description = "Push attempts before a message is dead-lettered."
  type        = number
  default     = 5

  validation {
    condition     = var.max_delivery_attempts >= 5 && var.max_delivery_attempts <= 100
    error_message = "max_delivery_attempts must be between 5 and 100."
  }
}

variable "message_retention" {
  description = "How long undelivered messages stay on the topic subscriptions."
  type        = string
  default     = "86400s"
}

variable "exclude_from_default_bucket" {
  description = "Stop the routed logs from also being stored in the _Default bucket. Routing to a sink is free; storage is not, so leaving this on avoids paying twice for the same log."
  type        = bool
  default     = true
}

variable "create_verify_subscription" {
  description = "Also create a pull subscription on the topic, so a test harness can read the same entries the adapter sees. Off for customer deployments."
  type        = bool
  default     = true
}

variable "debug_log_events" {
  description = "Log every forwarded event and one raw entry per push. Useful when validating a new deployment; multiplies log volume by the request rate, so leave it off in steady state."
  type        = bool
  default     = false
}
