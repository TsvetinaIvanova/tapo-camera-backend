# Generic Python Lambda: execution role with basic logging only, a
# Terraform-managed log group, and the function, packaged either as a
# deterministic single-file zip (source_file) or a container image pinned
# by digest (image_uri).
# Service-specific permissions are deliberately NOT passed in here: callers
# attach their own least-privilege policies to `role_name`, so what each
# function may do stays visible in its component file.

locals {
  is_image = var.image_uri != null

  # Suffix swap rather than dirname(): dirname() normalizes "./x" to "x",
  # which would change the function's `filename` and force an update.
  output_path = local.is_image ? null : "${trimsuffix(var.source_file, ".py")}.zip"
}

data "archive_file" "this" {
  count = local.is_image ? 0 : 1

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
  function_name = var.function_name
  role          = aws_iam_role.this.arn

  # Changing package_type replaces the function (Lambda can't convert in place).
  package_type     = local.is_image ? "Image" : "Zip"
  image_uri        = var.image_uri
  runtime          = local.is_image ? null : var.runtime
  handler          = local.is_image ? null : var.handler
  filename         = local.is_image ? null : data.archive_file.this[0].output_path
  source_code_hash = local.is_image ? null : data.archive_file.this[0].output_base64sha256

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

  lifecycle {
    precondition {
      condition     = (var.source_file == null) != (var.image_uri == null)
      error_message = "Set exactly one of source_file (zip) or image_uri (container image)."
    }
    precondition {
      condition     = !local.is_image || length(var.layers) == 0
      error_message = "Layers can't be used with image functions; build dependencies into the image."
    }
  }
}
