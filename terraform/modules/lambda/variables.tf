variable "function_name" {
  description = "Lambda function name; also used for the role (<name>-role) and log group (/aws/lambda/<name>)"
  type        = string
}

variable "source_file" {
  description = "Path to the single-file Python handler; zipped next to it as <basename>.zip"
  type        = string

  validation {
    condition     = endswith(var.source_file, ".py")
    error_message = "source_file must be a .py file."
  }
}

variable "handler" {
  description = "Lambda handler entry point"
  type        = string
  default     = "handler.lambda_handler"
}

variable "runtime" {
  description = "Lambda runtime"
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
  description = "Layer ARNs"
  type        = list(string)
  default     = []
}

variable "log_retention_days" {
  description = "CloudWatch log retention in days"
  type        = number
  default     = 30
}
