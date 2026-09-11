variable "project_id" {
  description = "GCP project the demo site and pipeline live in. Set it in terraform.tfvars."
  type        = string
}

variable "region" {
  description = "Region for Cloud Run, the serverless NEG and Artifact Registry."
  type        = string
  default     = "us-central1"
}

variable "name_prefix" {
  description = "Name prefix for every resource."
  type        = string
  default     = "agent-analytics-mock-site"
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
