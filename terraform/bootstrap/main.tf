# ── Bootstrap stack ───────────────────────────────────────
# Owns the GitHub OIDC provider and the roles CI uses to plan/apply the
# main stack. Applied locally with admin credentials, never from CI, so
# the CI roles can't modify their own permissions.

terraform {
  required_version = ">= 1.7"

  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 5.0"
    }
  }

  backend "s3" {
    bucket       = "tapo-cameras-backend-tf-state"
    key          = "tapo-camera-backend/bootstrap.tfstate"
    region       = "eu-central-1"
    use_lockfile = true
    encrypt      = true
  }
}

provider "aws" {
  region = var.aws_region

  default_tags {
    tags = {
      Project     = "tapo-camera-backend"
      Environment = var.environment
      ManagedBy   = "terraform"
    }
  }
}

data "aws_caller_identity" "current" {}

locals {
  account_id = data.aws_caller_identity.current.account_id
  region     = var.aws_region

  # Must match the backend block of the main stack (../backend.tf)
  main_state_key = "tapo-camera-backend/terraform.tfstate"
}
