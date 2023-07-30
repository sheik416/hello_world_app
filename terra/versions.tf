terraform {
  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 4.0"
    }
  }
}
provider "aws" {
  region     = "us-east-2"
  access_key = "AKIAVC53YZWW67U2F2WD"
  secret_key = "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"

  default_tags {
    tags = {
      Name = "architect-demo"
    }
  }
}