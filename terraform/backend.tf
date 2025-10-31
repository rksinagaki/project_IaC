terraform {
  backend "s3" {
    bucket         = "terraform-state-bucket-20251031"
    key            = "youtube-pipeline/terraform.tfstate"
    region         = "ap-northeast-1"
    encrypt        = true
    use_lockfile   = true
  }
}