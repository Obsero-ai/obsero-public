output "topic" {
  description = "Pub/Sub topic the log sink publishes into."
  value       = google_pubsub_topic.events.name
}

output "dead_letter_topic" {
  description = "Messages the adapter never accepted end up here, replayable."
  value       = google_pubsub_topic.dead_letter.name
}

output "dead_letter_subscription" {
  description = "Pull subscription for draining the dead-letter topic."
  value       = google_pubsub_subscription.dead_letter.name
}

output "push_subscription" {
  description = "Push subscription driving the adapter."
  value       = google_pubsub_subscription.push.name
}

output "verify_subscription" {
  description = "Pull subscription for the test harness. Null when create_verify_subscription is false."
  value       = var.create_verify_subscription ? google_pubsub_subscription.verify[0].name : null
}

output "adapter_service" {
  description = "Cloud Run adapter forwarding to Obsero."
  value       = google_cloud_run_v2_service.adapter.name
}

output "adapter_url" {
  description = "Adapter endpoint. Only the push identity may call it."
  value       = google_cloud_run_v2_service.adapter.uri
}

output "adapter_image" {
  description = "Image the adapter is running."
  value       = local.adapter_image
}

output "sink_name" {
  description = "Log Router sink filtered to the backend service."
  value       = google_logging_project_sink.this.name
}

output "sink_writer_identity" {
  description = "Identity the sink publishes as; holds pubsub.publisher on the topic."
  value       = google_logging_project_sink.this.writer_identity
}

output "logged_headers" {
  description = "Request headers the load balancer is logging."
  value       = var.logged_headers
}

output "backend_service" {
  description = "Backend service this module enabled logging on."
  value       = var.backend_service_name
}
