# Generic single-file Python Lambda: deterministic zip, execution role with
# basic logging only, a Terraform-managed log group, and the function.
# Service-specific permissions are deliberately NOT passed in here: callers
# attach their own least-privilege policies to `role_name`, so what each
# function may do stays visible in its component file.

locals {
  # Suffix swap rather than dirname(): dirname() normalizes "./x" to "x",
  # which would change the function's `filename` and force an update.
  output_path = "${trimsuffix(var.source_file, ".py")}.zip"
}

data "archive_file" "this" {
  type        = "zip"
  source_file = var.source_file
  output_path = local.output_path

  # Normalize permissions so the zip (and its hash) is identical on any
  # machine; otherwise a local 664 file vs CI's 644 forces a redeploy.
  output_file_mode = "0644"
}

resource "aws_iam_role" "this" {
  name = "${var.function_name}-role"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect    = "Allow"
      Principal = { Service = "lambda.amazonaws.com" }
      Action    = "sts:AssumeRole"
    }]
  })
}

resource "aws_iam_role_policy_attachment" "basic_execution" {
  role       = aws_iam_role.this.name
  policy_arn = "arn:aws:iam::aws:policy/service-role/AWSLambdaBasicExecutionRole"
}

# Named from the variable, not the function resource, so it is created
# first: if Lambda is invoked before the group exists, it auto-creates it
# and the Terraform-managed group then fails to create.
resource "aws_cloudwatch_log_group" "this" {
  name              = "/aws/lambda/${var.function_name}"
  retention_in_days = var.log_retention_days
}

resource "aws_lambda_function" "this" {
  function_name    = var.function_name
  role             = aws_iam_role.this.arn
  runtime          = var.runtime
  handler          = var.handler
  filename         = data.archive_file.this.output_path
  source_code_hash = data.archive_file.this.output_base64sha256

  layers      = var.layers
  timeout     = var.timeout
  memory_size = var.memory_size

  dynamic "environment" {
    for_each = length(var.environment) > 0 ? [1] : []
    content {
      variables = var.environment
    }
  }

  depends_on = [aws_cloudwatch_log_group.this]
}
