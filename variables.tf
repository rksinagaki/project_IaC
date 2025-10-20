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

variable "region_name" {
  description = "AWSリージョン名"
  type        = string
  default     = "ap-northeast-1"
}

variable "script_bucket_name" {
  description = "Glueジョブのスクリプト保存用S3バケット名"
  type        = string
  default     = "youtube-glue-job-script-1016" 
}

variable "alert_email_endpoint" {
  description = "SNSアラートの通知先となるEメールアドレス"
  type        = string
}