# ── Clips bucket ────────────────────────────────────────────

resource "aws_s3_bucket" "camera_clips" {
  bucket = var.bucket_name
}

resource "aws_s3_bucket_public_access_block" "camera_clips" {
  bucket = aws_s3_bucket.camera_clips.id

  block_public_acls       = true
  ignore_public_acls      = true
  block_public_policy     = true
  restrict_public_buckets = true
}

resource "aws_s3_bucket_server_side_encryption_configuration" "camera_clips" {
  bucket = aws_s3_bucket.camera_clips.id

  rule {
    apply_server_side_encryption_by_default {
      sse_algorithm = "AES256"
    }
  }
}

resource "aws_s3_bucket_versioning" "camera_clips" {
  bucket = aws_s3_bucket.camera_clips.id

  versioning_configuration {
    status = "Enabled"
  }
}

resource "aws_s3_bucket_lifecycle_configuration" "camera_clips" {
  bucket = aws_s3_bucket.camera_clips.id

  rule {
    id     = "transition-and-expire"
    status = "Enabled"

    filter {
      prefix = "clips/"
    }

    transition {
      days          = 30
      storage_class = "STANDARD_IA"
    }

    transition {
      days          = 60
      storage_class = "GLACIER"
    }

    expiration {
      days = var.clips_ttl_days
    }

    noncurrent_version_expiration {
      noncurrent_days = 30
    }
  }
}

# ── Clip metadata table ─────────────────────────────────────

resource "aws_dynamodb_table" "camera_clips" {
  name         = "tapo-camera-clips"
  billing_mode = "PAY_PER_REQUEST" # no capacity planning needed at home scale
  hash_key     = "camera_id"
  range_key    = "start_time"

  attribute {
    name = "camera_id"
    type = "S"
  }

  attribute {
    name = "start_time"
    type = "N"
  }

  attribute {
    name = "date"
    type = "S"
  }

  global_secondary_index {
    name            = "date-start_time-index"
    hash_key        = "date"
    range_key       = "start_time"
    projection_type = "ALL"
  }

  ttl {
    attribute_name = "ttl"
    enabled        = true
  }
}
