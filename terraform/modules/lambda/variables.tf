variable "function_name" {
  description = "The unique name for the Lambda function (e.g., youtube-scraper-channel-a)."
  type        = string
}

variable "ecr_repository_url" {
  description = "The URI of the ECR repository containing the Docker image."
  type        = string
}

variable "s3_data_lake_bucket_name" {
  description = "The name of the S3 bucket the Lambda function needs to read/write to."
  type        = string
}

variable "youtube_secret_arn" {
  description = "The ARN of the Secrets Manager secret containing the YouTube API Key."
  type        = string
}

variable "region_name" {
  description = "The AWS region (used for constructing ARN).."
  type        = string
  default     = "ap-northeast-1"
}

variable "project_tags" {
  description = "Tags to apply to all resources."
  type        = map(string)
  default = {}
}

variable "log_retention_days" {
  description = "Lambda logs retention days."
  type        = number
  default     = 60
}