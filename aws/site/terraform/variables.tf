variable "project" {
  description = "Name prefix for all resources."
  type        = string
  default     = "agent-analytics-mock-site"
}

variable "region" {
  description = "AWS region for the S3 origin bucket."
  type        = string
  default     = "us-east-1"
}

variable "obsero_ingest_url" {
  description = "Obsero ingest endpoint that receives one event per HTTP request."
  type        = string
  default     = "https://analytics-staging.obsero.ai/v1/events"
}

variable "obsero_site_token" {
  description = "Value sent as the x-obsero-key header."
  type        = string
  sensitive   = true
}
