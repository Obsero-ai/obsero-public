output "realtime_log_config_arn" {
  description = "Only set when log_source = \"realtime\". Attach to your cache behaviour: realtime_log_config_arn = module.<name>.realtime_log_config_arn"
  value       = local.realtime ? aws_cloudfront_realtime_log_config.this[0].arn : null
}

output "log_source" {
  description = "Which collection mode is active."
  value       = var.log_source
}

output "kinesis_stream_name" {
  description = "Stream CloudFront writes into. Null in standard mode, which has no Kinesis stream."
  value       = local.realtime ? aws_kinesis_stream.this[0].name : null
}

output "kinesis_stream_arn" {
  description = "ARN of the log stream, or null in standard mode."
  value       = local.realtime ? aws_kinesis_stream.this[0].arn : null
}

output "firehose_stream_name" {
  description = "Firehose delivery stream feeding the adapter."
  value       = aws_kinesis_firehose_delivery_stream.this.name
}

output "firehose_stream_arn" {
  description = "ARN of the delivery stream."
  value       = aws_kinesis_firehose_delivery_stream.this.arn
}

output "adapter_function_name" {
  description = "Adapter Lambda. Its env holds the authoritative log format and field order."
  value       = aws_lambda_function.adapter.function_name
}

output "adapter_log_group" {
  description = "Where to watch forwarding succeed or fail."
  value       = aws_cloudwatch_log_group.adapter.name
}

output "backup_bucket" {
  description = "Undeliverable batches land here after retries are exhausted."
  value       = aws_s3_bucket.backup.id
}

output "log_fields_in_order" {
  description = "Real-time fields as CloudFront actually emits them. Empty in standard mode, which is self-describing JSON."
  value       = local.realtime ? local.ordered_fields : []
}
