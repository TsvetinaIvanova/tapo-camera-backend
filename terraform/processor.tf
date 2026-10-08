# ── Processor Lambda (S3 upload -> thumbnail + metadata) ────

# Public layer maintained by serverless-ffmpeg project.
# This ARN is for eu-central-1 — update if you use a different region.
# Full list: https://github.com/nicholasgasior/aws-lambda-ffmpeg-layer
locals {
  ffmpeg_layer_arn = "arn:aws:lambda:eu-central-1:175033217214:layer:ffmpeg:1"
}

module "processor" {
  source = "./modules/lambda"

  function_name = "tapo-clip-processor"
  source_file   = "${path.module}/lambda/processor/handler.py"
  layers        = [local.ffmpeg_layer_arn]

  timeout     = 60  # seconds — thumbnail extraction is fast, but download may take a moment
  memory_size = 512 # MB — ffmpeg needs headroom; /tmp is 512MB by default

  environment = {
    DYNAMODB_TABLE   = aws_dynamodb_table.camera_clips.name
    S3_BUCKET        = aws_s3_bucket.camera_clips.id
    THUMBNAIL_PREFIX = "thumbnails"
    TTL_DAYS         = var.clips_ttl_days
  }
}

# ── IAM (beyond basic execution, which the module provides) ─

# Scoped S3 permissions:
# - GetObject on clips/ (read the uploaded clip)
# - PutObject on thumbnails/ (write the generated thumbnail)
# - GetObject on thumbnails/ (verify upload)
resource "aws_iam_role_policy" "lambda_s3" {
  name = "tapo-clip-processor-s3"
  role = module.processor.role_name

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
  role = module.processor.role_name

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
    lambda_function_arn = module.processor.arn
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
  function_name = module.processor.function_name
  principal     = "s3.amazonaws.com"
  source_arn    = aws_s3_bucket.camera_clips.arn
}
