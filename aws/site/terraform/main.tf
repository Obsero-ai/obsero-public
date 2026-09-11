# ---------------------------------------------------------------------------
# Step 1: a static mock site, private S3 origin behind CloudFront.
# CloudFront is the origin of the HTTP request logs that step 2 will stream
# to a third party via Kinesis Data Streams -> Firehose.
# ---------------------------------------------------------------------------

resource "random_id" "suffix" {
  byte_length = 4
}

locals {
  bucket_name = "${var.project}-${random_id.suffix.hex}"
  site_dir    = "${path.module}/../public"

  content_types = {
    html = "text/html; charset=utf-8"
    css  = "text/css; charset=utf-8"
    js   = "application/javascript; charset=utf-8"
    svg  = "image/svg+xml"
    ico  = "image/x-icon"
    png  = "image/png"
    jpg  = "image/jpeg"
  }
}

# --- Origin bucket ---------------------------------------------------------

resource "aws_s3_bucket" "site" {
  bucket = local.bucket_name
}

resource "aws_s3_bucket_public_access_block" "site" {
  bucket                  = aws_s3_bucket.site.id
  block_public_acls       = true
  block_public_policy     = true
  ignore_public_acls      = true
  restrict_public_buckets = true
}

resource "aws_s3_bucket_ownership_controls" "site" {
  bucket = aws_s3_bucket.site.id
  rule {
    object_ownership = "BucketOwnerEnforced"
  }
}

resource "aws_s3_bucket_server_side_encryption_configuration" "site" {
  bucket = aws_s3_bucket.site.id
  rule {
    apply_server_side_encryption_by_default {
      sse_algorithm = "AES256"
    }
  }
}

# Upload every file under site/, typed by extension. The etag means editing a
# file and re-applying re-uploads it.
resource "aws_s3_object" "site" {
  for_each = fileset(local.site_dir, "**")

  bucket       = aws_s3_bucket.site.id
  key          = each.value
  source       = "${local.site_dir}/${each.value}"
  etag         = filemd5("${local.site_dir}/${each.value}")
  content_type = lookup(local.content_types, lower(reverse(split(".", each.value))[0]), "application/octet-stream")
}

# --- CloudFront ------------------------------------------------------------

resource "aws_cloudfront_origin_access_control" "site" {
  name                              = local.bucket_name
  origin_access_control_origin_type = "s3"
  signing_behavior                  = "always"
  signing_protocol                  = "sigv4"
}

resource "aws_cloudfront_distribution" "site" {
  enabled             = true
  is_ipv6_enabled     = true
  comment             = "${var.project} mock site"
  default_root_object = "index.html"
  price_class         = "PriceClass_100"

  origin {
    origin_id                = "s3-${aws_s3_bucket.site.id}"
    domain_name              = aws_s3_bucket.site.bucket_regional_domain_name
    origin_access_control_id = aws_cloudfront_origin_access_control.site.id
  }

  default_cache_behavior {
    target_origin_id       = "s3-${aws_s3_bucket.site.id}"
    viewer_protocol_policy = "redirect-to-https"
    allowed_methods        = ["GET", "HEAD", "OPTIONS"]
    cached_methods         = ["GET", "HEAD"]
    compress               = true

    # Managed-CachingOptimized
    cache_policy_id = "658327ea-f89d-4fab-a63d-7e88639e58f6"

    # Logging is attached by the ingestion module via standard logging v2,
    # which collects from the distribution itself -- nothing to wire in here.
  }

  custom_error_response {
    error_code            = 403
    response_code         = 404
    response_page_path    = "/404.html"
    error_caching_min_ttl = 10
  }

  custom_error_response {
    error_code            = 404
    response_code         = 404
    response_page_path    = "/404.html"
    error_caching_min_ttl = 10
  }

  restrictions {
    geo_restriction {
      restriction_type = "none"
    }
  }

  viewer_certificate {
    cloudfront_default_certificate = true
  }
}

# --- Let only this distribution read the bucket ----------------------------

data "aws_iam_policy_document" "site" {
  statement {
    sid       = "AllowCloudFrontRead"
    effect    = "Allow"
    actions   = ["s3:GetObject"]
    resources = ["${aws_s3_bucket.site.arn}/*"]

    principals {
      type        = "Service"
      identifiers = ["cloudfront.amazonaws.com"]
    }

    condition {
      test     = "StringEquals"
      variable = "AWS:SourceArn"
      values   = [aws_cloudfront_distribution.site.arn]
    }
  }
}

resource "aws_s3_bucket_policy" "site" {
  bucket = aws_s3_bucket.site.id
  policy = data.aws_iam_policy_document.site.json

  depends_on = [aws_s3_bucket_public_access_block.site]
}

# ---------------------------------------------------------------------------
# The shippable pipeline, consumed exactly the way a customer consumes it:
# one module block, one ARN wired into the cache behaviour above.
# ---------------------------------------------------------------------------

module "ingestion" {
  source = "../../ingestion"

  name_prefix = var.project
  ingest_url  = var.obsero_ingest_url
  site_token  = var.obsero_site_token

  # Pay-as-you-go: CloudFront delivers straight into Firehose, no Kinesis shard.
  log_source       = "standard"
  distribution_arn = aws_cloudfront_distribution.site.arn

  # This is a test rig: we want to see exactly what gets forwarded, and
  # `make destroy` must not stall on a backup bucket nobody will replay.
  debug_log_events     = true
  backup_force_destroy = true
}
