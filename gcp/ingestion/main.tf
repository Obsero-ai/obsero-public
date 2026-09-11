# ---------------------------------------------------------------------------
# Load balancer request logs -> Cloud Logging -> Log Router sink -> Pub/Sub
# -> push subscription (OIDC) -> Cloud Run adapter -> analytics.
#
# Unlike the AWS module, this one DOES mutate a resource the customer owns: it
# turns request logging on for the named backend service and installs the
# header allow-list. That is the whole point -- there is no ARN to hand back
# and attach -- but it is worth knowing before you apply. It is reversible;
# see README.md.
# ---------------------------------------------------------------------------

data "google_project" "this" {
  project_id = var.project_id
}

resource "random_id" "suffix" {
  byte_length = 4
}

locals {
  # Pub/Sub's own service agent, which needs rights on both ends of the
  # dead-letter path before dead-lettering will work at all.
  pubsub_agent = "serviceAccount:service-${data.google_project.this.number}@gcp-sa-pubsub.iam.gserviceaccount.com"

  headers = join(",", var.logged_headers)

  # Service account IDs cap at 30 characters, well short of the 39 name_prefix
  # allows. Truncate rather than fail: the longest suffix used is "-adapter"
  # (8), so 21 characters of prefix always fits, and the cut could otherwise
  # leave a trailing hyphen, which is not a legal account_id either.
  #
  # Two deployments whose prefixes share their first 21 characters would
  # collide here. name_prefix is already required to be unique per project;
  # for service accounts that uniqueness has to land in the first 21.
  sa_prefix = replace(
    substr(var.name_prefix, 0, min(21, length(var.name_prefix))),
    "/-+$/",
    "",
  )

  adapter_dir = "${path.module}/adapter"
  adapter_files = sort(concat(
    ["index.mjs", "Dockerfile"],
  ))
  adapter_hash = substr(sha1(join(",", [
    for f in local.adapter_files : filesha1("${local.adapter_dir}/${f}")
  ])), 0, 12)

  build_adapter = var.adapter_image == null
  adapter_image = local.build_adapter ? "${var.region}-docker.pkg.dev/${var.project_id}/${google_artifact_registry_repository.adapter[0].repository_id}/adapter:${local.adapter_hash}" : var.adapter_image
}

# ---------------------------------------------------------------------------
# Request logging on the customer's backend service.
#
# Terraform cannot do this half. Both hashicorp/google and google-beta expose
# log_config with only enable / optional_fields / optional_mode / sample_rate;
# loggingHttpRequestHeaders is in the Compute v1 API and in gcloud but not in
# either provider. So the module shells out, keyed on a hash of the inputs so
# it re-runs when the header list changes and not otherwise.
#
# Revisit if the provider catches up.
# ---------------------------------------------------------------------------

# The allow-list is re-asserted on EVERY apply, deliberately.
#
# Terraform cannot model this field, so it also cannot detect it going missing.
# Any full-resource update to the backend service -- by this module, by the
# customer's own Terraform, or by hand in the console -- silently drops the
# header list while `terraform plan` still reports no changes. That failure is
# invisible: logs keep flowing, they just arrive with no headers to classify
# on, which is the one thing this pipeline exists to deliver.
#
# So the trigger is a timestamp rather than a hash of the inputs. Every apply
# shows one change and re-installs the list, which costs a two-second gcloud
# call and makes the drift self-healing.
resource "terraform_data" "request_logging" {
  triggers_replace = timestamp()

  provisioner "local-exec" {
    interpreter = ["/bin/bash", "-c"]
    command     = <<-EOT
      set -euo pipefail
      gcloud compute backend-services update ${var.backend_service_name} \
        --global \
        --project=${var.project_id} \
        --enable-logging \
        --logging-sample-rate=${var.sample_rate} \
        --logging-http-request-headers=${local.headers} \
        --quiet
    EOT
  }
}

# Removal lives on its own resource, with triggers that never change, so it
# fires only on a real `terraform destroy` of this module. Hanging it off
# request_logging above would run it on every apply -- which is exactly the bug
# this split fixes: the destroy provisioner stripped the allow-list mid-apply
# and left the pipeline shipping headerless events.
resource "terraform_data" "request_logging_cleanup" {
  triggers_replace = {
    project_id      = var.project_id
    backend_service = var.backend_service_name
  }

  # Leave the customer's backend service as we found it.
  provisioner "local-exec" {
    when        = destroy
    on_failure  = continue
    interpreter = ["/bin/bash", "-c"]
    command     = <<-EOT
      gcloud compute backend-services update ${self.triggers_replace.backend_service} \
        --global \
        --project=${self.triggers_replace.project_id} \
        --no-logging-http-request-headers \
        --quiet
    EOT
  }
}

# --- Pub/Sub ----------------------------------------------------------------

resource "google_pubsub_topic" "events" {
  project = var.project_id
  name    = "${var.name_prefix}-http-logs"
}

resource "google_pubsub_topic" "dead_letter" {
  project = var.project_id
  name    = "${var.name_prefix}-http-logs-dead-letter"

  message_storage_policy {
    allowed_persistence_regions = [var.region]
  }
}

# --- Log Router sink --------------------------------------------------------

# Scoped to this one load balancer. A project-wide sink would ship every
# request hitting every backend service in the project.
resource "google_logging_project_sink" "this" {
  project     = var.project_id
  name        = "${var.name_prefix}-lb-requests"
  destination = "pubsub.googleapis.com/${google_pubsub_topic.events.id}"

  filter = <<-EOT
    resource.type="http_load_balancer"
    resource.labels.backend_service_name="${var.backend_service_name}"
  EOT

  unique_writer_identity = true
}

# Without this the sink is created and silently publishes nothing.
resource "google_pubsub_topic_iam_member" "sink_publisher" {
  project = var.project_id
  topic   = google_pubsub_topic.events.name
  role    = "roles/pubsub.publisher"
  member  = google_logging_project_sink.this.writer_identity
}

# Routing to a sink is free; storing the same entries in _Default is not.
resource "google_logging_project_exclusion" "default_bucket" {
  count = var.exclude_from_default_bucket ? 1 : 0

  project     = var.project_id
  name        = "${var.name_prefix}-lb-requests-storage"
  description = "Routed to Pub/Sub by ${google_logging_project_sink.this.name}; not stored again."

  filter = <<-EOT
    resource.type="http_load_balancer"
    resource.labels.backend_service_name="${var.backend_service_name}"
  EOT
}

# --- Adapter image ----------------------------------------------------------

resource "google_artifact_registry_repository" "adapter" {
  count = local.build_adapter ? 1 : 0

  project       = var.project_id
  location      = var.region
  repository_id = "${var.name_prefix}-adapter-${random_id.suffix.hex}"
  format        = "DOCKER"
  description   = "Obsero ingestion adapter images"
}

resource "terraform_data" "adapter_image" {
  count = local.build_adapter ? 1 : 0

  triggers_replace = local.adapter_hash

  provisioner "local-exec" {
    interpreter = ["/bin/bash", "-c"]
    command     = <<-EOT
      set -euo pipefail
      gcloud auth configure-docker ${var.region}-docker.pkg.dev --quiet
      docker build -t ${local.adapter_image} ${local.adapter_dir}
      docker push ${local.adapter_image}
    EOT
  }

  depends_on = [google_artifact_registry_repository.adapter]
}

# --- Adapter ----------------------------------------------------------------

resource "google_service_account" "adapter" {
  project      = var.project_id
  account_id   = "${local.sa_prefix}-adapter"
  display_name = "Obsero ingestion adapter"
}

resource "google_cloud_run_v2_service" "adapter" {
  project             = var.project_id
  name                = "${var.name_prefix}-adapter"
  location            = var.region
  deletion_protection = false

  # Pub/Sub pushes from outside the VPC. The gate is IAM, not the network:
  # only the push identity below holds run.invoker.
  ingress = "INGRESS_TRAFFIC_ALL"

  template {
    service_account = google_service_account.adapter.email

    scaling {
      min_instance_count = 0
      max_instance_count = 10
    }

    containers {
      image = local.adapter_image

      ports {
        container_port = 8080
      }

      resources {
        limits = {
          cpu    = "1"
          memory = "512Mi"
        }
      }

      env {
        name  = "OBSERO_INGEST_URL"
        value = var.ingest_url
      }
      env {
        name  = "OBSERO_SITE_TOKEN"
        value = var.site_token
      }
      env {
        name  = "EXCLUDED_HEADERS"
        value = join(",", var.excluded_headers)
      }
      env {
        name  = "SKIPPED_PATHS"
        value = join(",", var.skipped_paths)
      }
      env {
        name  = "DEBUG_LOG_EVENTS"
        value = tostring(var.debug_log_events)
      }
    }
  }

  depends_on = [terraform_data.adapter_image]
}

# --- Push subscription ------------------------------------------------------

# A separate identity from the adapter's own: this one only proves who is
# calling. No shared secret, unlike Firehose's X-Amz-Firehose-Access-Key.
resource "google_service_account" "pusher" {
  project      = var.project_id
  account_id   = "${local.sa_prefix}-pusher"
  display_name = "Obsero ingestion Pub/Sub push identity"
}

resource "google_cloud_run_v2_service_iam_member" "pusher_invoker" {
  project  = var.project_id
  location = google_cloud_run_v2_service.adapter.location
  name     = google_cloud_run_v2_service.adapter.name
  role     = "roles/run.invoker"
  member   = "serviceAccount:${google_service_account.pusher.email}"
}

# Pub/Sub mints the OIDC token as this account, so it must be able to act as it.
resource "google_service_account_iam_member" "pubsub_token_creator" {
  service_account_id = google_service_account.pusher.name
  role               = "roles/iam.serviceAccountTokenCreator"
  member             = local.pubsub_agent
}

resource "google_pubsub_subscription" "push" {
  project = var.project_id
  name    = "${var.name_prefix}-push"
  topic   = google_pubsub_topic.events.id

  ack_deadline_seconds       = 60
  message_retention_duration = var.message_retention

  push_config {
    push_endpoint = google_cloud_run_v2_service.adapter.uri

    oidc_token {
      service_account_email = google_service_account.pusher.email
      audience              = google_cloud_run_v2_service.adapter.uri
    }
  }

  dead_letter_policy {
    dead_letter_topic     = google_pubsub_topic.dead_letter.id
    max_delivery_attempts = var.max_delivery_attempts
  }

  retry_policy {
    minimum_backoff = "10s"
    maximum_backoff = "600s"
  }

  depends_on = [
    google_cloud_run_v2_service_iam_member.pusher_invoker,
    google_service_account_iam_member.pubsub_token_creator,
  ]
}

# Dead-lettering needs the service agent to publish into the dead-letter topic
# and to ack on the source subscription. Missing either one and messages retry
# forever instead of parking.
resource "google_pubsub_topic_iam_member" "dead_letter_publisher" {
  project = var.project_id
  topic   = google_pubsub_topic.dead_letter.name
  role    = "roles/pubsub.publisher"
  member  = local.pubsub_agent
}

resource "google_pubsub_subscription_iam_member" "dead_letter_subscriber" {
  project      = var.project_id
  subscription = google_pubsub_subscription.push.name
  role         = "roles/pubsub.subscriber"
  member       = local.pubsub_agent
}

# Lets the dead-letter topic be drained and replayed as a queue, rather than
# read back out of gzip in a bucket the way Firehose's S3 backup works.
resource "google_pubsub_subscription" "dead_letter" {
  project = var.project_id
  name    = "${var.name_prefix}-dead-letter"
  topic   = google_pubsub_topic.dead_letter.id

  ack_deadline_seconds       = 60
  message_retention_duration = var.message_retention

  expiration_policy {
    ttl = ""
  }
}

# --- Verification -----------------------------------------------------------

# A second, independent reader on the same topic. The push subscription acks
# and forgets; this one keeps the raw entries around so a harness can score a
# run against what the load balancer actually logged.
resource "google_pubsub_subscription" "verify" {
  count = var.create_verify_subscription ? 1 : 0

  project = var.project_id
  name    = "${var.name_prefix}-verify"
  topic   = google_pubsub_topic.events.id

  ack_deadline_seconds       = 30
  message_retention_duration = var.message_retention

  expiration_policy {
    ttl = ""
  }
}
