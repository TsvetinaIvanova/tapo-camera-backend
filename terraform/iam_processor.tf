# ── IAM role for the Lambda function ─────────────────────

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
        Sid    = "ReadClips"
        Effect = "Allow"
        Action = ["s3:GetObject"]
        Resource = "${aws_s3_bucket.camera_clips.arn}/clips/*"
      },
      {
        Sid    = "WriteThumbnails"
        Effect = "Allow"
        Action = ["s3:PutObject"]
        Resource = "${aws_s3_bucket.camera_clips.arn}/thumbnails/*"
      },
      {
        Sid    = "GetObjectMetadata"
        Effect = "Allow"
        Action = ["s3:HeadObject"]
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
