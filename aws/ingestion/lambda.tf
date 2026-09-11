# ---------------------------------------------------------------------------
# The adapter. Firehose's HTTP destination speaks its own protocol -- a batch
# envelope, an X-Amz-Firehose-Access-Key header, a required JSON ack -- so it
# cannot POST to the ingest API directly. This translates, in your account,
# stripping excluded headers before anything leaves.
# ---------------------------------------------------------------------------

data "archive_file" "adapter" {
  type        = "zip"
  source_dir  = "${path.module}/lambda/adapter"
  output_path = "${path.module}/.build/adapter-${random_id.suffix.hex}.zip"
}

data "aws_iam_policy_document" "lambda_assume" {
  statement {
    effect  = "Allow"
    actions = ["sts:AssumeRole"]
    principals {
      type        = "Service"
      identifiers = ["lambda.amazonaws.com"]
    }
  }
}

resource "aws_iam_role" "adapter" {
  name               = "${var.name_prefix}-adapter"
  assume_role_policy = data.aws_iam_policy_document.lambda_assume.json
  tags               = local.tags
}

resource "aws_iam_role_policy_attachment" "adapter_logs" {
  role       = aws_iam_role.adapter.name
  policy_arn = "arn:aws:iam::aws:policy/service-role/AWSLambdaBasicExecutionRole"
}

resource "aws_cloudwatch_log_group" "adapter" {
  name              = "/aws/lambda/${var.name_prefix}-adapter"
  retention_in_days = var.log_retention_days
  tags              = local.tags
}

resource "aws_lambda_function" "adapter" {
  function_name    = "${var.name_prefix}-adapter"
  role             = aws_iam_role.adapter.arn
  runtime          = "nodejs22.x"
  handler          = "index.handler"
  filename         = data.archive_file.adapter.output_path
  source_code_hash = data.archive_file.adapter.output_base64sha256
  timeout          = 60
  memory_size      = 512
  tags             = local.tags

  environment {
    variables = {
      OBSERO_INGEST_URL     = var.ingest_url
      OBSERO_SITE_TOKEN     = var.site_token
      FIREHOSE_ACCESS_KEY   = random_password.firehose_key.result
      CLOUDFRONT_LOG_FIELDS = join(",", local.ordered_fields)
      LOG_FORMAT            = local.standard ? "standard-json" : "realtime-tsv"
      EXCLUDED_HEADERS      = join(",", var.excluded_headers)
      SKIPPED_PATHS         = join(",", var.skipped_paths)
      FORWARD_CONCURRENCY   = tostring(var.forward_concurrency)
      DEBUG_LOG_EVENTS      = tostring(var.debug_log_events)
    }
  }

  depends_on = [aws_cloudwatch_log_group.adapter]
}

# Firehose cannot SigV4-sign to a Function URL, so the URL is unauthenticated
# at the AWS layer and the shared Firehose access key is what the handler
# actually checks. The URL is not secret but is useless without that key.
resource "aws_lambda_function_url" "adapter" {
  function_name      = aws_lambda_function.adapter.function_name
  authorization_type = "NONE"
}
