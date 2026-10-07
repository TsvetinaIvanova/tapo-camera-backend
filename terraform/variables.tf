variable "aws_region" {
  description = "AWS region to deploy into"
  type        = string
  default     = "eu-central-1"
}

variable "bucket_name" {
  description = "Globally unique S3 bucket name for camera clips"
  default     = "vladaya-tapo-cameras" # your actual bucket name
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

variable "clips_ttl_days" {
  description = "Number of days to keep clips in S3 and DynamoDB before automatic deletion"
  type        = number
  default     = 120
}

# Deliberately no default: this is the only alerting path, so a missing
# value should fail the plan loudly rather than silently drop the SNS
# subscription. CI supplies it via TF_VAR_alert_email; locally it comes
# from terraform.tfvars (gitignored, keeps the address out of the repo).
variable "alert_email" {
  description = "Email address to receive CloudWatch alarm notifications"
  type        = string
  nullable    = false

  validation {
    condition     = can(regex("^[^@\\s]+@[^@\\s]+\\.[^@\\s]+$", var.alert_email))
    error_message = "alert_email must be a valid email address."
  }
}

variable "api_cors_extra_origins" {
  description = "Origins allowed to call the API besides the S3 website (e.g. local frontend dev server)"
  type        = list(string)
  default     = ["http://localhost:8000"]
}
