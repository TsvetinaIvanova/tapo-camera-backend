output "bucket_name" {
  description = "S3 bucket name for camera clips"
  value       = aws_s3_bucket.camera_clips.id
}

output "bucket_arn" {
  description = "S3 bucket ARN"
  value       = aws_s3_bucket.camera_clips.arn
}

