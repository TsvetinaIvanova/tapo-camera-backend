variable "aws_region" {
  description = "AWS region the main stack deploys into"
  type        = string
  default     = "eu-central-1"
}

variable "environment" {
  description = "Environment name for tagging"
  type        = string
  default     = "prod"
}

variable "github_repo" {
  description = "GitHub repository (owner/name) allowed to assume the CI roles"
  type        = string
  default     = "TsvetinaIvanova/tapo-camera-backend"
}

variable "state_bucket" {
  description = "S3 bucket holding Terraform state"
  type        = string
  default     = "tapo-cameras-backend-tf-state"
}

# The following must match the main stack (../variables.tf)
variable "bucket_name" {
  description = "Camera clips bucket name used by the main stack"
  type        = string
  default     = "vladaya-tapo-cameras"
}

variable "poller_user_name" {
  description = "IAM user name of the poller managed by the main stack"
  type        = string
  default     = "tapo-poller"
}
