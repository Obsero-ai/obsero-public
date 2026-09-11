# Attaching the pipeline to a load balancer you already run.
#
# Nothing about the backend service is declared here -- it is looked up by name
# and left alone apart from having request logging turned on. That works
# whether or not Terraform manages it.

variable "project_id" {
  type = string
}

variable "backend_service_name" {
  description = "Name of the existing global backend service to log."
  type        = string
}

variable "obsero_site_token" {
  type      = string
  sensitive = true
}

data "google_compute_backend_service" "existing" {
  project = var.project_id
  name    = var.backend_service_name
}

module "obsero_ingestion" {
  source = "../.."

  project_id  = var.project_id
  name_prefix = "acme-prod"
  site_token  = var.obsero_site_token

  backend_service_name = data.google_compute_backend_service.existing.name

  # Narrow the allow-list if you classify on less than the default.
  # logged_headers = ["user-agent", "signature-agent", "signature-input", "signature"]
}

output "topic" {
  value = module.obsero_ingestion.topic
}

output "adapter_service" {
  value = module.obsero_ingestion.adapter_service
}
