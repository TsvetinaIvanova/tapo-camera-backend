terraform {
  backend "s3" {
    bucket         = "tapo-cameras-backend-tf-state"
    key            = "tapo-camera-backend/terraform.tfstate"
    region         = "eu-central-1"
    dynamodb_table = "tapo-tf-state-lock"
    encrypt        = true
  }
}