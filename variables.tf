variable "data_bucket_name" {
  description = "データパイプライン用S3バケット名 (生データ、加工データ、レポート、一時ファイルを格納)"
  type        = string
  default     = "youtube-data-pipeline-bucket-1016" 
}

variable "project_tags" {
  description = "リソースに適用するタグ"
  type        = map(string)
  default = {
    Project = "YouTubeDataPipeline"
    Environment = "Dev"
  }
}