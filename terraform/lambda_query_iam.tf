# ── IAM role for the query Lambda ────────────────────────

resource "aws_iam_role" "lambda_query" {
  name = "tapo-clip-query-role"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect    = "Allow"
      Principal = { Service = "lambda.amazonaws.com" }
      Action    = "sts:AssumeRole"
    }]
  })
}

resource "aws_iam_role_policy_attachment" "lambda_query_basic" {
  role       = aws_iam_role.lambda_query.name
  policy_arn = "arn:aws:iam::aws:policy/service-role/AWSLambdaBasicExecutionRole"
}

# DynamoDB read — scoped to this table only
resource "aws_iam_role_policy" "lambda_query_dynamodb" {
  name = "tapo-clip-query-dynamodb"
  role = aws_iam_role.lambda_query.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Sid    = "ReadClipMetadata"
      Effect = "Allow"
      Action = [
        "dynamodb:Query",
        "dynamodb:Scan",
      ]
      Resource = [
        aws_dynamodb_table.camera_clips.arn,
        "${aws_dynamodb_table.camera_clips.arn}/index/*",
      ]
    }]
  })
}

# S3 presigned URL generation — needs GetObject on clips and thumbnails
resource "aws_iam_role_policy" "lambda_query_s3" {
  name = "tapo-clip-query-s3"
  role = aws_iam_role.lambda_query.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Sid    = "GeneratePresignedUrls"
      Effect = "Allow"
      Action = ["s3:GetObject"]
      Resource = [
        "${aws_s3_bucket.camera_clips.arn}/clips/*",
        "${aws_s3_bucket.camera_clips.arn}/thumbnails/*",
      ]
    }]
  })
}
