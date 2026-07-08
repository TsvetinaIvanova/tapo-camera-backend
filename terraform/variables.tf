variable "aws_region" {
  description = "AWS region to deploy into"
  type        = string
  default     = "eu-central-1"
}

variable "bucket_name" {
  description = "Globally unique S3 bucket name for camera clips"
  type        = string
}

variable "environment" {
  description = "Environment name for tagging"
  type        = string
  default     = "prod"
}

variable "poller_user_name" {
  description = "IAM user name for the local poller script (least-privilege upload access)"
  type        = string
  default     = "tapo-poller"
}

variable "bucket_name" {
  description = "Globally unique S3 bucket name for camera clips"
  type        = string
  default     = "vladaya-tapo-cameras"   # your actual bucket name
}