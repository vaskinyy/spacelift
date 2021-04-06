# providers
provider "aws" {
  version = "~> 2.0"
  region = "eu-west-2"
}

terraform {
  required_providers {
    spacelift = {
      source = "spacelift.io/spacelift-io/spacelift"
    }
  }
}

# ECR
resource "aws_ecr_repository" "spacelift" {
  name = "spacelift"
}

# ECS

