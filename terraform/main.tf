terraform {
  required_version = ">= 1.7"

  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 5.0"
    }
    archive = {
      source  = "hashicorp/archive"
      version = "~> 2.8"
    }
    random = {
      source  = "hashicorp/random"
      version = "~> 3.9"
    }
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
  # Created in bootstrap (terraform/bootstrap/workload_boundary.tf), applied
  # by an admin. Every IAM role and user in this stack must carry it: the
  # apply role can't create or grant permissions to an unbounded identity.
  workload_boundary_arn = "arn:aws:iam::${data.aws_caller_identity.current.account_id}:policy/tapo-workload-boundary"
}
