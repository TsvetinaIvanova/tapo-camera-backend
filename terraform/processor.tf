# ── Processor Lambda (S3 upload -> thumbnail + metadata) ────

# Container image (terraform/lambda/processor/Dockerfile: handler + minimal
# source-built ffmpeg). deploy.yml builds, smoke-tests and pushes it, then
# passes its digest to apply, so the function runs exactly the tested image.
# Without that variable (PR plans, local plans), the newest image is used.
data "aws_ecr_image" "processor" {
  repository_name = aws_ecr_repository.processor.name
  most_recent     = true
}

locals {
  processor_image_digest = coalesce(var.processor_image_digest, data.aws_ecr_image.processor.image_digest)
}

module "processor" {
  source = "./modules/lambda"

  function_name = "tapo-clip-processor"
  image_uri     = "${aws_ecr_repository.processor.repository_url}@${local.processor_image_digest}"

  timeout     = 60  # seconds — thumbnail extraction is fast, but download may take a moment
  memory_size = 512 # MB — ffmpeg needs headroom; /tmp is 512MB by default

  environment = {
    DYNAMODB_TABLE   = aws_dynamodb_table.camera_clips.name
    S3_BUCKET        = aws_s3_bucket.camera_clips.id
    THUMBNAIL_PREFIX = "thumbnails"
    TTL_DAYS         = var.clips_ttl_days
  }
}

# ── IAM (beyond logging, which the module provides) ─

# Scoped S3 permissions:
# - GetObject on clips/ (download the uploaded clip; also authorizes the
#   HEAD request download_file makes first; there is no s3:HeadObject action)
# - PutObject on thumbnails/ (write the generated thumbnail)
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
      Sid      = "WriteClipMetadata"
      Effect   = "Allow"
      Action   = ["dynamodb:PutItem"]
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

# Permission for S3 to invoke the Lambda.
# statement_id was renamed (from AllowS3Invoke) when the function moved from
# zip to image: that change replaces the function, which deletes its resource
# policy, but this resource's inputs stayed the same, so Terraform wouldn't
# have recreated it and S3 would silently have lost permission to invoke.
# statement_id forces replacement, so the rename recreates it on the new function.
resource "aws_lambda_permission" "allow_s3" {
  statement_id  = "AllowS3InvokeProcessor"
  action        = "lambda:InvokeFunction"
  function_name = module.processor.function_name
  principal     = "s3.amazonaws.com"
  source_arn    = aws_s3_bucket.camera_clips.arn
}

# ── Container image repository ──────────────────────────────
# Image build of the processor (terraform/lambda/processor/Dockerfile),
# replacing the third-party ffmpeg layer. Built and pushed by deploy.yml.

resource "aws_ecr_repository" "processor" {
  name = "tapo-clip-processor"

  # Tags are never reused, so a tag always means the same image; the
  # function will be pinned by digest anyway.
  image_tag_mutability = "IMMUTABLE"

  image_scanning_configuration {
    scan_on_push = true # basic scanning: free, OS-package CVEs (incl. Debian's ffmpeg)
  }
}

# Lambda pulls the image with its service principal. Managed here so it's
# reviewable and doesn't drift: otherwise Lambda adds a statement itself
# when the function is created. Scoped to this one function.
resource "aws_ecr_repository_policy" "processor" {
  repository = aws_ecr_repository.processor.name

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Sid       = "LambdaImagePull"
      Effect    = "Allow"
      Principal = { Service = "lambda.amazonaws.com" }
      Action    = ["ecr:BatchGetImage", "ecr:GetDownloadUrlForLayer"]
      Condition = {
        # Unqualified ARN, or this function with a version/alias qualifier
        StringLike = {
          "aws:sourceArn" = [module.processor.arn, "${module.processor.arn}:*"]
        }
      }
    }]
  })
}

resource "aws_ecr_lifecycle_policy" "processor" {
  repository = aws_ecr_repository.processor.name

  policy = jsonencode({
    rules = [
      {
        rulePriority = 1
        description  = "Expire untagged images (superseded build layers) after 1 day"
        selection = {
          tagStatus   = "untagged"
          countType   = "sinceImagePushed"
          countUnit   = "days"
          countNumber = 1
        }
        action = { type = "expire" }
      },
      {
        # Images are ~220 MB compressed; 5 is enough to roll back a few
        # deploys. Keep this above the number of deploys you might revert.
        rulePriority = 2
        description  = "Keep the 5 most recent images"
        selection = {
          tagStatus   = "any"
          countType   = "imageCountMoreThan"
          countNumber = 5
        }
        action = { type = "expire" }
      },
    ]
  })
}
