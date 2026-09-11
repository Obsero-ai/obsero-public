output "site_url" {
  description = "Public URL of the mock site."
  value       = "http://${google_compute_global_address.site.address}"
}

output "site_ip" {
  description = "Load balancer IP."
  value       = google_compute_global_address.site.address
}

output "backend_service" {
  description = "Backend service the ingestion module logs."
  value       = google_compute_backend_service.site.name
}

output "cloud_run_service" {
  description = "Cloud Run service backing the site."
  value       = google_cloud_run_v2_service.site.name
}

output "site_image" {
  description = "Image currently deployed."
  value       = local.image
}

output "logged_headers" {
  description = "Request headers the load balancer is logging."
  value       = module.ingestion.logged_headers
}

output "topic" {
  description = "Pub/Sub topic the log sink writes to."
  value       = module.ingestion.topic
}

output "dead_letter_topic" {
  description = "Undeliverable messages land here."
  value       = module.ingestion.dead_letter_topic
}

output "adapter_service" {
  description = "Cloud Run adapter forwarding to Obsero."
  value       = module.ingestion.adapter_service
}

output "verify_subscription" {
  description = "Pull subscription the test harness reads to score a run."
  value       = module.ingestion.verify_subscription
}
