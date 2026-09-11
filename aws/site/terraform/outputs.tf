output "site_url" {
  description = "Public URL of the mock site."
  value       = "https://${aws_cloudfront_distribution.site.domain_name}"
}

output "bucket_name" {
  description = "Private S3 origin bucket."
  value       = aws_s3_bucket.site.id
}

output "distribution_id" {
  description = "CloudFront distribution ID (step 2 attaches real-time logs here)."
  value       = aws_cloudfront_distribution.site.id
}

output "log_source" {
  description = "Active log collection mode."
  value       = module.ingestion.log_source
}

output "firehose_stream" {
  description = "Firehose delivery stream forwarding to Obsero."
  value       = module.ingestion.firehose_stream_name
}

output "adapter_function" {
  description = "Adapter Lambda; holds the authoritative log field order."
  value       = module.ingestion.adapter_function_name
}

output "adapter_log_group" {
  description = "Where to watch forwarding succeed or fail."
  value       = module.ingestion.adapter_log_group
}

output "backup_bucket" {
  description = "Undeliverable batches land here."
  value       = module.ingestion.backup_bucket
}
