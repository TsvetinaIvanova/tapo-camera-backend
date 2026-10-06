# ── ffmpeg Lambda Layer ───────────────────────────────────
# Public layer maintained by serverless-ffmpeg project.
# This ARN is for eu-central-1 — update if you use a different region.
# Full list: https://github.com/nicholasgasior/aws-lambda-ffmpeg-layer
locals {
  ffmpeg_layer_arn = "arn:aws:lambda:eu-central-1:175033217214:layer:ffmpeg:1"
}

# ── Lambda deployment package ─────────────────────────────
# Terraform zips the handler automatically from the local source file.
data "archive_file" "lambda_processor" {
  type        = "zip"
  source_file = "${path.module}/lambda/processor/handler.py"
  output_path = "${path.module}/lambda/processor/handler.zip"
}

# ── Lambda function ───────────────────────────────────────
resource "aws_lambda_function" "clip_processor" {
  function_name    = "tapo-clip-processor"
  role             = aws_iam_role.lambda_processor.arn
  runtime          = "python3.12"
  handler          = "handler.lambda_handler"
  filename         = data.archive_file.lambda_processor.output_path
  source_code_hash = data.archive_file.lambda_processor.output_base64sha256

  layers = [local.ffmpeg_layer_arn]

  timeout     = 60  # seconds — thumbnail extraction is fast, but download may take a moment
  memory_size = 512 # MB — ffmpeg needs headroom; /tmp is 512MB by default

  environment {
    variables = {
      DYNAMODB_TABLE   = aws_dynamodb_table.camera_clips.name
      S3_BUCKET        = aws_s3_bucket.camera_clips.id
      THUMBNAIL_PREFIX = "thumbnails"
      TTL_DAYS         = var.clips_ttl_days
    }
  }
}

# ── CloudWatch Log Group ──────────────────────────────────
# Explicitly managed so Terraform controls retention
resource "aws_cloudwatch_log_group" "clip_processor" {
  name              = "/aws/lambda/${aws_lambda_function.clip_processor.function_name}"
  retention_in_days = 30
}

# ── S3 → Lambda trigger ───────────────────────────────────
resource "aws_s3_bucket_notification" "clip_upload" {
  bucket = aws_s3_bucket.camera_clips.id

  lambda_function {
    lambda_function_arn = aws_lambda_function.clip_processor.arn
    events              = ["s3:ObjectCreated:*"]
    filter_prefix       = "clips/"
    filter_suffix       = ".mp4"
  }

  depends_on = [aws_lambda_permission.allow_s3]
}

# Permission for S3 to invoke the Lambda
resource "aws_lambda_permission" "allow_s3" {
  statement_id  = "AllowS3Invoke"
  action        = "lambda:InvokeFunction"
  function_name = aws_lambda_function.clip_processor.function_name
  principal     = "s3.amazonaws.com"
  source_arn    = aws_s3_bucket.camera_clips.arn
}

# ── Outputs ───────────────────────────────────────────────
output "lambda_function_name" {
  value = aws_lambda_function.clip_processor.function_name
}

output "lambda_log_group" {
  value = aws_cloudwatch_log_group.clip_processor.name
}
