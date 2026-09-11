# Attaching the pipeline to a CloudFront distribution Terraform already manages.
#
# The module never touches your distribution. It builds the pipeline and hands
# back one ARN, which you attach to whichever cache behaviours you want logged.

terraform {
  required_version = ">= 1.5"
  required_providers {
    aws = { source = "hashicorp/aws", version = ">= 5.40, < 7.0" }
  }
}

provider "aws" {
  region = "us-east-1"
}

variable "obsero_site_token" {
  type      = string
  sensitive = true
}

module "obsero_ingestion" {
  source = "../.." # or a git ref: github.com/obsero/aws-ingestion//ingestion?ref=v1

  name_prefix = "acme-prod"
  site_token  = var.obsero_site_token

  # Optional:
  # ingest_url       = "https://analytics.obsero.ai/v1/events"
  # sampling_rate    = 100
  # excluded_headers = ["authorization", "cookie", "set-cookie", "x-api-key"]
  # skipped_paths    = ["/health", "/favicon.ico", "/_next/static"]
}

resource "aws_cloudfront_distribution" "site" {
  enabled = true

  # ... your origins, aliases, certificates, unchanged ...

  default_cache_behavior {
    target_origin_id       = "your-origin"
    viewer_protocol_policy = "redirect-to-https"
    allowed_methods        = ["GET", "HEAD", "OPTIONS"]
    cached_methods         = ["GET", "HEAD"]
    cache_policy_id        = "658327ea-f89d-4fab-a63d-7e88639e58f6" # Managed-CachingOptimized

    # This one line turns the pipeline on.
    realtime_log_config_arn = module.obsero_ingestion.realtime_log_config_arn
  }

  # Repeat on any ordered_cache_behavior you also want logged; behaviours
  # without the ARN emit nothing.

  restrictions {
    geo_restriction {
      restriction_type = "none"
    }
  }

  viewer_certificate {
    cloudfront_default_certificate = true
  }
}

output "watch_forwarding" {
  value = "aws logs tail ${module.obsero_ingestion.adapter_log_group} --follow"
}
