# ── Query Lambda ─────────────────────────────────────────

data "archive_file" "lambda_query" {
  type        = "zip"
  source_file = "${path.module}/lambda/query/handler.py"
  output_path = "${path.module}/lambda/query/handler.zip"
}

resource "aws_lambda_function" "clip_query" {
  function_name    = "tapo-clip-query"
  role             = aws_iam_role.lambda_query.arn
  runtime          = "python3.12"
  handler          = "handler.lambda_handler"
  filename         = data.archive_file.lambda_query.output_path
  source_code_hash = data.archive_file.lambda_query.output_base64sha256

  timeout     = 15
  memory_size = 256

  environment {
    variables = {
      DYNAMODB_TABLE       = aws_dynamodb_table.camera_clips.name
      S3_BUCKET            = aws_s3_bucket.camera_clips.id
      PRESIGNED_URL_EXPIRY = "3600"   # 1 hour
    }
  }
}

resource "aws_cloudwatch_log_group" "clip_query" {
  name              = "/aws/lambda/${aws_lambda_function.clip_query.function_name}"
  retention_in_days = 30
}

# ── API Gateway ───────────────────────────────────────────

resource "aws_apigatewayv2_api" "tapo" {
  name          = "tapo-camera-api"
  protocol_type = "HTTP"

  cors_configuration {
    allow_origins = ["*"]   # tighten this to your S3 website URL once deployed
    allow_methods = ["GET", "OPTIONS"]
    allow_headers = ["Content-Type", "x-api-key"]
    max_age       = 300
  }
}

resource "aws_apigatewayv2_stage" "tapo" {
  api_id      = aws_apigatewayv2_api.tapo.id
  name        = "$default"
  auto_deploy = true
}

resource "aws_apigatewayv2_integration" "clip_query" {
  api_id             = aws_apigatewayv2_api.tapo.id
  integration_type   = "AWS_PROXY"
  integration_uri    = aws_lambda_function.clip_query.invoke_arn
  integration_method = "POST"
}

resource "aws_apigatewayv2_route" "get_clips" {
  api_id    = aws_apigatewayv2_api.tapo.id
  route_key = "GET /clips"
  target    = "integrations/${aws_apigatewayv2_integration.clip_query.id}"

  authorization_type = "CUSTOM"
  authorizer_id      = aws_apigatewayv2_authorizer.shared_secret.id
}

resource "aws_lambda_permission" "allow_apigw" {
  statement_id  = "AllowAPIGatewayInvoke"
  action        = "lambda:InvokeFunction"
  function_name = aws_lambda_function.clip_query.function_name
  principal     = "apigateway.amazonaws.com"
  source_arn    = "${aws_apigatewayv2_api.tapo.execution_arn}/*/*"
}

# ── Static website S3 bucket ──────────────────────────────

resource "aws_s3_bucket" "frontend" {
  bucket = "${var.bucket_name}-frontend"
}

resource "aws_s3_bucket_website_configuration" "frontend" {
  bucket = aws_s3_bucket.frontend.id

  index_document { suffix = "index.html" }
  error_document { key    = "index.html" }
}

resource "aws_s3_bucket_public_access_block" "frontend" {
  bucket = aws_s3_bucket.frontend.id

  block_public_acls       = false
  ignore_public_acls      = false
  block_public_policy     = false
  restrict_public_buckets = false
}

resource "aws_s3_bucket_policy" "frontend" {
  bucket     = aws_s3_bucket.frontend.id
  depends_on = [aws_s3_bucket_public_access_block.frontend]

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Sid       = "PublicReadGetObject"
      Effect    = "Allow"
      Principal = "*"
      Action    = "s3:GetObject"
      Resource  = "${aws_s3_bucket.frontend.arn}/*"
    }]
  })
}

# ── Outputs ───────────────────────────────────────────────

output "api_endpoint" {
  description = "API Gateway endpoint — use this in the frontend config"
  value       = aws_apigatewayv2_stage.tapo.invoke_url
}

output "frontend_bucket" {
  description = "S3 bucket for the static frontend"
  value       = aws_s3_bucket.frontend.id
}

output "frontend_url" {
  description = "Static website URL"
  value       = "http://${aws_s3_bucket_website_configuration.frontend.website_endpoint}"
}
