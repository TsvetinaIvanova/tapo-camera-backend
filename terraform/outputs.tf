output "bucket_name" {
  description = "S3 bucket name for camera clips"
  value       = aws_s3_bucket.camera_clips.id
}

output "bucket_arn" {
  description = "S3 bucket ARN"
  value       = aws_s3_bucket.camera_clips.arn
}

output "poller_access_key_id" {
  description = "Access key ID for the poller IAM user"
  value       = aws_iam_access_key.poller.id
}

output "poller_secret_access_key" {
  description = "Secret access key for the poller IAM user — store this in your poller's environment, never commit it"
  value       = aws_iam_access_key.poller.secret
  sensitive   = true
}
