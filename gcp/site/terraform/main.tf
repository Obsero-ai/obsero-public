# ---------------------------------------------------------------------------
# Step 1: a static mock site behind a global external Application Load Balancer
# with Cloud CDN in front of it.
#
# The AWS rig is S3 + CloudFront. That does not port: a GCP backend *bucket*
# has no logConfig field at all, so a Cloud Storage origin emits no LB request
# logs and there is nothing for the pipeline to ship. The origin must be a
# backend *service*, so the same pages are served from Cloud Run behind a
# serverless NEG. Real customers are mostly unaffected -- apps on Cloud Run,
# GKE or a MIG already use backend services.
# ---------------------------------------------------------------------------

resource "random_id" "suffix" {
  byte_length = 4
}

locals {
  app_dir = "${path.module}/.."

  # Hashing the sources makes the image tag change exactly when the site does,
  # so `terraform apply` after editing a page rebuilds and redeploys, and a
  # no-op apply is genuinely a no-op.
  app_files = sort(concat(
    ["server.mjs", "Dockerfile"],
    [for f in fileset("${local.app_dir}/public", "**") : "public/${f}"],
  ))
  app_hash = substr(sha1(join(",", [for f in local.app_files : filesha1("${local.app_dir}/${f}")])), 0, 12)

  registry = "${var.region}-docker.pkg.dev/${var.project_id}/${google_artifact_registry_repository.site.repository_id}"
  image    = "${local.registry}/site:${local.app_hash}"
}

# --- Container image -------------------------------------------------------

resource "google_artifact_registry_repository" "site" {
  location      = var.region
  repository_id = "${var.name_prefix}-${random_id.suffix.hex}"
  format        = "DOCKER"
  description   = "Images for the Obsero GCP ingestion test rig"
}

# Built locally rather than through Cloud Build: in this project Cloud Build
# runs as the default compute service account, which cannot read its own
# staging bucket. A local build needs only docker and a configured credential
# helper, and is faster besides.
resource "terraform_data" "site_image" {
  triggers_replace = local.app_hash

  provisioner "local-exec" {
    interpreter = ["/bin/bash", "-c"]
    command     = <<-EOT
      set -euo pipefail
      gcloud auth configure-docker ${var.region}-docker.pkg.dev --quiet
      docker build -t ${local.image} ${local.app_dir}
      docker push ${local.image}
    EOT
  }

  depends_on = [google_artifact_registry_repository.site]
}

# --- Cloud Run origin ------------------------------------------------------

resource "google_cloud_run_v2_service" "site" {
  name     = "${var.name_prefix}-site"
  location = var.region

  # Only the load balancer may reach it. Requests that skip the LB would skip
  # the request logging the whole pipeline depends on.
  ingress             = "INGRESS_TRAFFIC_INTERNAL_LOAD_BALANCER"
  deletion_protection = false

  template {
    scaling {
      min_instance_count = 0
      max_instance_count = 3
    }

    containers {
      image = local.image
      ports {
        container_port = 8080
      }
      resources {
        limits = {
          cpu    = "1"
          memory = "512Mi"
        }
      }
    }
  }

  depends_on = [terraform_data.site_image]
}

# The LB forwards viewer requests unauthenticated; the ingress setting above is
# what keeps the service private, not this binding.
resource "google_cloud_run_v2_service_iam_member" "public" {
  location = google_cloud_run_v2_service.site.location
  name     = google_cloud_run_v2_service.site.name
  role     = "roles/run.invoker"
  member   = "allUsers"
}

# --- Load balancer + Cloud CDN ---------------------------------------------

resource "google_compute_region_network_endpoint_group" "site" {
  name                  = "${var.name_prefix}-neg"
  region                = var.region
  network_endpoint_type = "SERVERLESS"

  cloud_run {
    service = google_cloud_run_v2_service.site.name
  }
}

resource "google_compute_backend_service" "site" {
  name                  = "${var.name_prefix}-backend"
  load_balancing_scheme = "EXTERNAL_MANAGED"
  protocol              = "HTTPS"
  enable_cdn            = true

  backend {
    group = google_compute_region_network_endpoint_group.site.id
  }

  cdn_policy {
    cache_mode  = "CACHE_ALL_STATIC"
    default_ttl = 60
    client_ttl  = 60
    max_ttl     = 300

    # The harness tags every request ?mt=<runId>-<seq>, so keying on the query
    # string keeps each one a distinct object. Cache hits are logged either
    # way -- the load balancer logs the request, not the origin fetch -- but
    # this keeps the rig honest about how many requests reached Cloud Run.
    cache_key_policy {
      include_host         = true
      include_protocol     = true
      include_query_string = true
    }
  }

  # Turning logging on here is the half Terraform can do. The header allow-list
  # -- the entire reason this design is cheaper than the AWS one -- is not in
  # the provider schema, so the ingestion module patches it in via gcloud.
  # Anything set here is preserved by that patch.
  log_config {
    enable      = true
    sample_rate = 1.0
  }
}

resource "google_compute_url_map" "site" {
  name            = "${var.name_prefix}-urlmap"
  default_service = google_compute_backend_service.site.id
}

resource "google_compute_target_http_proxy" "site" {
  name    = "${var.name_prefix}-proxy"
  url_map = google_compute_url_map.site.id
}

resource "google_compute_global_address" "site" {
  name = "${var.name_prefix}-ip"
}

# HTTP only: a Google-managed certificate needs a domain, and the rig is
# addressed by IP. The pipeline is indifferent -- it reads request logs, not
# the connection.
resource "google_compute_global_forwarding_rule" "site" {
  name                  = "${var.name_prefix}-fr"
  load_balancing_scheme = "EXTERNAL_MANAGED"
  port_range            = "80"
  target                = google_compute_target_http_proxy.site.id
  ip_address            = google_compute_global_address.site.id
}

# ---------------------------------------------------------------------------
# The shippable pipeline, consumed exactly the way a customer consumes it:
# one module block naming the backend service whose traffic to log.
# ---------------------------------------------------------------------------

module "ingestion" {
  source = "../../ingestion"

  project_id  = var.project_id
  region      = var.region
  name_prefix = var.name_prefix

  backend_service_name = google_compute_backend_service.site.name
  ingest_url           = var.obsero_ingest_url
  site_token           = var.obsero_site_token

  # This is a test rig: we want to see exactly what gets forwarded.
  debug_log_events = true
}
