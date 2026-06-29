resource "aws_dynamodb_table" "camera_clips" {
  name         = "tapo-camera-clips"
  billing_mode = "PAY_PER_REQUEST"   # no capacity planning needed at home scale
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

output "dynamodb_table_name" {
  value = aws_dynamodb_table.camera_clips.name
}