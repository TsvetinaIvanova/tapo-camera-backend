output "dynamodb_table_name" {
  value = aws_dynamodb_table.camera_clips.name
}

output "lambda_function_name" {
  value = module.processor.function_name
}

output "lambda_log_group" {
  value = module.processor.log_group_name
}

output "api_endpoint" {
  description = "API Gateway endpoint — use this in the frontend config"
  value       = aws_apigatewayv2_stage.tapo.invoke_url
}

output "frontend_bucket" {
  description = "S3 bucket for the static frontend"
  value       = aws_s3_bucket.frontend.id
}

output "frontend_url" {
  description = "Static website URL (HTTP only)"
  value       = "http://${aws_s3_bucket_website_configuration.frontend.website_endpoint}"
}

output "frontend_https_url" {
  description = "Frontend over HTTPS, via the bucket's regional REST endpoint"
  value       = "https://${aws_s3_bucket.frontend.bucket_regional_domain_name}/index.html"
}

output "api_shared_secret" {
  description = "Shared secret for the frontend's access-code prompt (sensitive — run: terraform output -raw api_shared_secret)"
  value       = random_password.api_shared_secret.result
  sensitive   = true
}

output "sns_topic_arn" {
  description = "SNS topic ARN for camera alerts"
  value       = aws_sns_topic.alerts.arn
}

output "bucket_name" {
  description = "S3 bucket name for camera clips"
  value       = aws_s3_bucket.camera_clips.id
}

output "bucket_arn" {
  description = "S3 bucket ARN"
  value       = aws_s3_bucket.camera_clips.arn
}

output "processor_image_repository_url" {
  description = "ECR repository for the processor Lambda image"
  value       = aws_ecr_repository.processor.repository_url
}
