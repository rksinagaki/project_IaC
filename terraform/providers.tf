terraform {
  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 6.0"
    }

    google = {
      source  = "hashicorp/google"
      version = ">= 7.0"
    }
  }
}

provider "aws" {
  region = "ap-northeast-1" 
}

provider "google" {
  project = var.gcp_project_id
  region = var.gcp_region
}