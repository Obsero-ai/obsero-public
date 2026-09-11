# ---------------------------------------------------------------------------
# CloudFront HTTP logs -> Kinesis -> Firehose -> adapter Lambda -> analytics.
#
# This module does NOT touch your CloudFront distribution. It builds the
# pipeline and hands back `realtime_log_config_arn`; you attach that to the
# cache behaviour you want logged. See README.md.
# ---------------------------------------------------------------------------

locals {
  # CloudFront emits real-time log fields in ITS OWN canonical order, not the
  # order given in the log config. The adapter parses positionally, so the
  # field list handed to both sides is sorted into this order. Getting this
  # wrong silently shifts every column.
  canonical_fields = [
    "timestamp", "c-ip", "time-to-first-byte", "sc-status", "sc-bytes",
    "cs-method", "cs-protocol", "cs-host", "cs-uri-stem", "cs-bytes",
    "x-edge-location", "x-host-header", "time-taken", "cs-protocol-version",
    "c-ip-version", "cs-user-agent", "cs-referer", "cs-cookie", "cs-uri-query",
    "x-edge-response-result-type", "x-forwarded-for", "ssl-protocol",
    "ssl-cipher", "x-edge-result-type", "fle-encrypted-fields", "fle-status",
    "sc-content-type", "sc-content-len", "sc-range-start", "sc-range-end",
    "c-port", "x-edge-detailed-result-type", "c-country", "cs-accept-encoding",
    "cs-accept", "cache-behavior-path-pattern", "cs-headers",
    "cs-header-names", "cs-headers-count", "primary-distribution-id",
    "primary-distribution-dns-name", "origin-fbl", "origin-lbl", "asn",
  ]

  ordered_fields = [
    for field in local.canonical_fields : field if contains(var.log_fields, field)
  ]

  tags = merge(var.tags, { ManagedBy = "obsero-ingestion" })

  realtime = var.log_source == "realtime"
  standard = var.log_source == "standard"
}

# cs-uri-stem is what the adapter reports as `path`, and cs-headers is the
# whole point of the pipeline. Fail early rather than ship empty events.
resource "terraform_data" "validate_config" {
  lifecycle {
    precondition {
      condition     = !local.standard || var.distribution_arn != null
      error_message = "log_source = \"standard\" requires distribution_arn."
    }
    precondition {
      condition     = !local.realtime || (contains(var.log_fields, "cs-uri-stem") && contains(var.log_fields, "cs-method") && contains(var.log_fields, "sc-status"))
      error_message = "log_fields must include cs-uri-stem, cs-method and sc-status."
    }
    precondition {
      condition     = !local.realtime || contains(var.log_fields, "cs-headers")
      error_message = "log_fields must include cs-headers, or forwarded events carry no request headers to classify on."
    }
    precondition {
      condition     = !local.standard || (contains(var.standard_log_fields, "cs-uri-stem") && contains(var.standard_log_fields, "cs-method") && contains(var.standard_log_fields, "sc-status") && contains(var.standard_log_fields, "cs(User-Agent)"))
      error_message = "standard_log_fields must include cs-uri-stem, cs-method, sc-status and cs(User-Agent)."
    }
  }
}

resource "random_id" "suffix" {
  byte_length = 4
}

resource "random_password" "firehose_key" {
  length  = 40
  special = false
}

# --- Kinesis: what CloudFront writes into ----------------------------------

resource "aws_kinesis_stream" "this" {
  count = local.realtime ? 1 : 0

  name             = "${var.name_prefix}-http-logs"
  shard_count      = var.kinesis_shard_count
  retention_period = var.kinesis_retention_hours
  tags             = local.tags

  stream_mode_details {
    stream_mode = "PROVISIONED"
  }
}

data "aws_iam_policy_document" "cloudfront_assume" {
  statement {
    effect  = "Allow"
    actions = ["sts:AssumeRole"]
    principals {
      type        = "Service"
      identifiers = ["cloudfront.amazonaws.com"]
    }
  }
}

resource "aws_iam_role" "cloudfront_logger" {
  count = local.realtime ? 1 : 0

  name               = "${var.name_prefix}-cloudfront-logger"
  assume_role_policy = data.aws_iam_policy_document.cloudfront_assume.json
  tags               = local.tags
}

resource "aws_iam_role_policy" "cloudfront_logger" {
  count = local.realtime ? 1 : 0

  role = aws_iam_role.cloudfront_logger[0].id
  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect = "Allow"
      Action = [
        "kinesis:DescribeStreamSummary",
        "kinesis:DescribeStream",
        "kinesis:PutRecord",
        "kinesis:PutRecords",
      ]
      Resource = aws_kinesis_stream.this[0].arn
    }]
  })
}

# Attach the ARN this exports to your distribution's cache behaviour.
resource "aws_cloudfront_realtime_log_config" "this" {
  count = local.realtime ? 1 : 0

  name          = "${var.name_prefix}-realtime"
  sampling_rate = var.sampling_rate
  fields        = local.ordered_fields

  endpoint {
    stream_type = "Kinesis"
    kinesis_stream_config {
      role_arn   = aws_iam_role.cloudfront_logger[0].arn
      stream_arn = aws_kinesis_stream.this[0].arn
    }
  }

  depends_on = [aws_iam_role_policy.cloudfront_logger, terraform_data.validate_config]
}

# --- Backup bucket for batches the endpoint never accepted ------------------

resource "aws_s3_bucket" "backup" {
  bucket = "${var.name_prefix}-log-backup-${random_id.suffix.hex}"
  tags   = local.tags

  # Without this, `terraform destroy` fails with BucketNotEmpty the moment a
  # single batch has ever been backed up here. That refusal is the right
  # default -- the objects are events that never reached Obsero.
  force_destroy = var.backup_force_destroy
}

resource "aws_s3_bucket_public_access_block" "backup" {
  bucket                  = aws_s3_bucket.backup.id
  block_public_acls       = true
  block_public_policy     = true
  ignore_public_acls      = true
  restrict_public_buckets = true
}

resource "aws_s3_bucket_server_side_encryption_configuration" "backup" {
  bucket = aws_s3_bucket.backup.id
  rule {
    apply_server_side_encryption_by_default {
      sse_algorithm = "AES256"
    }
  }
}

resource "aws_s3_bucket_lifecycle_configuration" "backup" {
  bucket = aws_s3_bucket.backup.id
  rule {
    id     = "expire-undelivered"
    status = "Enabled"
    filter {}
    expiration {
      days = var.backup_retention_days
    }
  }
}

# --- Firehose ---------------------------------------------------------------

data "aws_iam_policy_document" "firehose_assume" {
  statement {
    effect  = "Allow"
    actions = ["sts:AssumeRole"]
    principals {
      type        = "Service"
      identifiers = ["firehose.amazonaws.com"]
    }
  }
}

resource "aws_iam_role" "firehose" {
  name               = "${var.name_prefix}-firehose"
  assume_role_policy = data.aws_iam_policy_document.firehose_assume.json
  tags               = local.tags
}

resource "aws_iam_role_policy" "firehose" {
  role = aws_iam_role.firehose.id
  policy = jsonencode({
    Version = "2012-10-17"
    Statement = concat(local.realtime ? [
      {
        Effect = "Allow"
        Action = [
          "kinesis:DescribeStream",
          "kinesis:GetShardIterator",
          "kinesis:GetRecords",
          "kinesis:ListShards",
        ]
        Resource = aws_kinesis_stream.this[0].arn
      },
      ] : [], [
      {
        Effect = "Allow"
        Action = [
          "s3:AbortMultipartUpload",
          "s3:GetBucketLocation",
          "s3:GetObject",
          "s3:ListBucket",
          "s3:ListBucketMultipartUploads",
          "s3:PutObject",
        ]
        Resource = [aws_s3_bucket.backup.arn, "${aws_s3_bucket.backup.arn}/*"]
      },
      {
        Effect   = "Allow"
        Action   = ["logs:PutLogEvents"]
        Resource = "${aws_cloudwatch_log_group.firehose.arn}:*"
      },
    ])
  })
}

resource "aws_cloudwatch_log_group" "firehose" {
  name              = "/aws/kinesisfirehose/${var.name_prefix}"
  retention_in_days = var.log_retention_days
  tags              = local.tags
}

resource "aws_cloudwatch_log_stream" "firehose" {
  name           = "HttpEndpointDelivery"
  log_group_name = aws_cloudwatch_log_group.firehose.name
}

resource "aws_kinesis_firehose_delivery_stream" "this" {
  name        = "${var.name_prefix}-ingest"
  destination = "http_endpoint"

  # Standard logging v2 writes via the AWSServiceRoleForLogDelivery SLR, whose
  # policy allows firehose:PutRecordBatch ONLY on streams tagged
  # LogDeliveryEnabled=true. Without this tag CloudFront silently delivers
  # nothing -- no error on the delivery, the stream, or in CloudTrail.
  tags = local.standard ? merge(local.tags, { LogDeliveryEnabled = "true" }) : local.tags

  # Realtime mode pulls from Kinesis. Standard mode is Direct PUT: CloudFront
  # writes into Firehose itself, so there is no stream to pay for.
  dynamic "kinesis_source_configuration" {
    for_each = local.realtime ? [1] : []
    content {
      kinesis_stream_arn = aws_kinesis_stream.this[0].arn
      role_arn           = aws_iam_role.firehose.arn
    }
  }

  http_endpoint_configuration {
    name               = "analytics-adapter"
    url                = aws_lambda_function_url.adapter.function_url
    access_key         = random_password.firehose_key.result
    role_arn           = aws_iam_role.firehose.arn
    buffering_size     = var.buffering_size
    buffering_interval = var.buffering_interval
    retry_duration     = var.retry_duration
    s3_backup_mode     = "FailedDataOnly"

    request_configuration {
      content_encoding = "NONE"
    }

    cloudwatch_logging_options {
      enabled         = true
      log_group_name  = aws_cloudwatch_log_group.firehose.name
      log_stream_name = aws_cloudwatch_log_stream.firehose.name
    }

    s3_configuration {
      role_arn           = aws_iam_role.firehose.arn
      bucket_arn         = aws_s3_bucket.backup.arn
      buffering_size     = 5
      buffering_interval = 300
      compression_format = "GZIP"
      prefix             = "failed/"
    }
  }

  depends_on = [aws_iam_role_policy.firehose]
}

# ---------------------------------------------------------------------------
# Standard logging v2: CloudFront delivers straight into Firehose, no Kinesis
# Data Stream and therefore no per-shard idle cost.
#
# The trade is header fidelity. Standard logs expose only User-Agent, Referer,
# Cookie and Host -- there is no cs-headers field -- so Web Bot Auth signature
# headers and client hints are not available. Use log_source = "realtime" if you
# need them.
#
# Delivered as JSON with named fields, so unlike real-time logs there is no
# positional parsing and no canonical field-order trap.
# ---------------------------------------------------------------------------

resource "aws_cloudwatch_log_delivery_source" "this" {
  count = local.standard ? 1 : 0

  name         = "${var.name_prefix}-access-logs"
  log_type     = "ACCESS_LOGS"
  resource_arn = var.distribution_arn
  tags         = local.tags

  depends_on = [terraform_data.validate_config]
}

resource "aws_cloudwatch_log_delivery_destination" "this" {
  count = local.standard ? 1 : 0

  name          = "${var.name_prefix}-firehose"
  output_format = "json"
  tags          = local.tags

  delivery_destination_configuration {
    destination_resource_arn = aws_kinesis_firehose_delivery_stream.this.arn
  }
}

resource "aws_cloudwatch_log_delivery" "this" {
  count = local.standard ? 1 : 0

  delivery_source_name     = aws_cloudwatch_log_delivery_source.this[0].name
  delivery_destination_arn = aws_cloudwatch_log_delivery_destination.this[0].arn
  record_fields            = var.standard_log_fields
  tags                     = local.tags
}
