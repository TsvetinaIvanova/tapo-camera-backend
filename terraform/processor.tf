# ── Processor Lambda (S3 upload -> thumbnail + metadata) ────

# Public layer maintained by serverless-ffmpeg project.
# This ARN is for eu-central-1 — update if you use a different region.
# Full list: https://github.com/nicholasgasior/aws-lambda-ffmpeg-layer
locals {
  ffmpeg_layer_arn = "arn:aws:lambda:eu-central-1:175033217214:layer:ffmpeg:1"

  processor_function_name = "tapo-clip-processor"
}

# Terraform zips the handler automatically from the local source file.
data "archive_file" "lambda_processor" {
  type        = "zip"
  source_file = "${path.module}/lambda/processor/handler.py"
  output_path = "${path.module}/lambda/processor/handler.zip"

  # Normalize permissions so the zip (and its hash) is identical on any
  # machine; otherwise a local 664 file vs CI's 644 forces a redeploy.
  output_file_mode = "0644"
}

resource "aws_lambda_function" "clip_processor" {
  function_name    = local.processor_function_name
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

  # Log group must exist before the function can be invoked, otherwise
  # Lambda auto-creates it and the Terraform-managed one fails to create.
  depends_on = [aws_cloudwatch_log_group.clip_processor]
}

# Explicitly managed so Terraform controls retention
resource "aws_cloudwatch_log_group" "clip_processor" {
  name              = "/aws/lambda/${local.processor_function_name}"
  retention_in_days = 30
}

# ── IAM ─────────────────────────────────────────────────────

resource "aws_iam_role" "lambda_processor" {
  name = "tapo-clip-processor-role"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect    = "Allow"
      Principal = { Service = "lambda.amazonaws.com" }
      Action    = "sts:AssumeRole"
    }]
  })
}

# Basic Lambda execution (CloudWatch Logs)
resource "aws_iam_role_policy_attachment" "lambda_basic" {
  role       = aws_iam_role.lambda_processor.name
  policy_arn = "arn:aws:iam::aws:policy/service-role/AWSLambdaBasicExecutionRole"
}

# Scoped S3 permissions:
# - GetObject on clips/ (read the uploaded clip)
# - PutObject on thumbnails/ (write the generated thumbnail)
# - GetObject on thumbnails/ (verify upload)
resource "aws_iam_role_policy" "lambda_s3" {
  name = "tapo-clip-processor-s3"
  role = aws_iam_role.lambda_processor.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Sid      = "ReadClips"
        Effect   = "Allow"
        Action   = ["s3:GetObject"]
        Resource = "${aws_s3_bucket.camera_clips.arn}/clips/*"
      },
      {
        Sid      = "WriteThumbnails"
        Effect   = "Allow"
        Action   = ["s3:PutObject"]
        Resource = "${aws_s3_bucket.camera_clips.arn}/thumbnails/*"
      },
      {
        Sid      = "GetObjectMetadata"
        Effect   = "Allow"
        Action   = ["s3:HeadObject"]
        Resource = "${aws_s3_bucket.camera_clips.arn}/clips/*"
      }
    ]
  })
}

# DynamoDB write permission — scoped to this one table
resource "aws_iam_role_policy" "lambda_dynamodb" {
  name = "tapo-clip-processor-dynamodb"
  role = aws_iam_role.lambda_processor.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Sid    = "WriteClipMetadata"
      Effect = "Allow"
      Action = [
        "dynamodb:PutItem",
        "dynamodb:UpdateItem"
      ]
      Resource = aws_dynamodb_table.camera_clips.arn
    }]
  })
}

# ── S3 -> Lambda trigger ────────────────────────────────────

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
