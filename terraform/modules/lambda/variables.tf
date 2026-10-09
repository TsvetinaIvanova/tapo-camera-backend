variable "function_name" {
  description = "Lambda function name; also used for the role (<name>-role) and log group (/aws/lambda/<name>)"
  type        = string
}

variable "source_file" {
  description = "Zip packaging: path to the single-file Python handler; zipped next to it as <basename>.zip. Set this or image_uri."
  type        = string
  default     = null

  validation {
    condition     = endswith(coalesce(var.source_file, "unset.py"), ".py")
    error_message = "source_file must be a .py file."
  }
}

variable "image_uri" {
  description = "Image packaging: ECR image URI, pinned by digest (repo@sha256:...). Set this or source_file."
  type        = string
  default     = null

  validation {
    condition     = var.image_uri == null || can(regex("@sha256:[0-9a-f]{64}$", var.image_uri))
    error_message = "image_uri must be pinned by digest (…@sha256:<64 hex>), not a tag."
  }
}

variable "handler" {
  description = "Lambda handler entry point (zip packaging only; images use their CMD)"
  type        = string
  default     = "handler.lambda_handler"
}

variable "runtime" {
  description = "Lambda runtime (zip packaging only; images bring their own)"
  type        = string
  default     = "python3.12"
}

variable "timeout" {
  description = "Timeout in seconds"
  type        = number
  default     = 15
}

variable "memory_size" {
  description = "Memory in MB"
  type        = number
  default     = 128
}

variable "environment" {
  description = "Environment variables"
  type        = map(string)
  default     = {}
}

variable "layers" {
  description = "Layer ARNs (zip packaging only; Lambda doesn't allow layers on image functions)"
  type        = list(string)
  default     = []
}

variable "log_retention_days" {
  description = "CloudWatch log retention in days"
  type        = number
  default     = 30
}
