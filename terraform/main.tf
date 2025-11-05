/* 手動で設定するべき項目
  ・Lambdaのコンテナイメージ(先に作っておく必要がある)
  ・SecretManagerへのGoogle YouTube API Key
  ・SecretMangerへのBigQueryのサービスアカウントキー
  ・Glueのスクリプト

/*
 * S3データレイクバケットの作成
 */
resource "aws_s3_bucket" "s3_data_lake_bucket" {
  bucket = var.data_bucket_name
  tags = var.project_tags
  force_destroy = true
}

resource "aws_s3_bucket_public_access_block" "s3_data_lake_block" {
  bucket                  = aws_s3_bucket.s3_data_lake_bucket.id
  block_public_acls       = true
  block_public_policy     = true
  ignore_public_acls      = true
  restrict_public_buckets = true
}

/*
 * S3データレイク,ライフサイクルルール定義
 */
resource "aws_s3_bucket_lifecycle_configuration" "s3_data_lake_lifecycle" {
  bucket = aws_s3_bucket.s3_data_lake_bucket.id

  rule {
    id     = "youtube_project_data_lifecycle"
    status = "Enabled"

    transition {
      days          = 30
      storage_class = "STANDARD_IA"
    }

    expiration {
      days = 60 
    }

    noncurrent_version_expiration {
      noncurrent_days = 30
    }
  }
}

/*
 * awsリポジトリ(ECR)の定義
 */
# resource "aws_ecr_repository" "lambda_ecr_repository" {
#   name                 = "youtube-lambda-scraper-repository"
#   image_tag_mutability = "MUTABLE"

#   image_scanning_configuration {
#     scan_on_push = true
#   }

#   force_delete = true
# }

data "aws_ecr_repository" "lambda_ecr_repository" {
  name                 = "youtube-lambda-scraper-repository"
}

/*
 * Secret managerの定義(API Keyは手動で設定)
 */
# Secrets Managerの枠組みとポリシーを作成
module "youtube_secret" {
  source = "terraform-aws-modules/secrets-manager/aws"
  version = "2.0.0"

  name_prefix             = "project-youtube-youtube-api-key"
  description             = "YouTube Data API Key for data scraper"
  recovery_window_in_days = 14
  create_random_password = false 
  secret_string = jsonencode({
    API_KEY = var.youtube_api_key
  })
  create_policy = false
}

/*
 * Lambdaの定義
 */
module "youtube_scraper_channel" {
  source = "./modules/lambda"

  function_name          = "youtube-lambda-scraper"
  ecr_repository_url     = data.aws_ecr_repository.lambda_ecr_repository.repository_url
  s3_data_lake_bucket_name = aws_s3_bucket.s3_data_lake_bucket.id
  youtube_secret_arn     = module.youtube_secret.secret_arn
  region_name            = var.region_name
  project_tags           = var.project_tags
}

/*
 * Lambda自体のアラーム
 */
module "lambda_function_failure_alarm" {
  source              = "terraform-aws-modules/cloudwatch/aws//modules/metric-alarm"
  version             = "5.7.2"

  alarm_name          = "lambda-function-failed-alarm"
  alarm_description   = "Lambda関数が実行時エラー（タイムアウト、認証失敗など）を返した場合に発報"
  comparison_operator = "GreaterThanThreshold"
  evaluation_periods  = 1
  threshold           = 0
  period              = 600
  statistic           = "Sum"
  
  metric_name = "Errors"
  namespace   = "AWS/Lambda"

  dimensions = { 
    FunctionName = module.youtube_scraper_channel.lambda_name
  }

  treat_missing_data = "notBreaching"

  alarm_actions = [aws_sns_topic.alert_topic_sfn.arn]
}

/*
 * SFNの定義
 */
# SFNの定義に必要なIAMロール
resource "aws_iam_role" "sfn_glue_execution_role" {
  name = "sfn-glue-execution-role"
  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Action    = "sts:AssumeRole"
      Effect    = "Allow"
      Principal = { Service = "states.amazonaws.com" }
    }]
  })
}

# SFNのポリシー（別途で記述）
resource "aws_iam_policy" "startcrawler_cloudwatch_policy" {
  name        = "AllowStartCrawlerCloudWatch"
  description = "Allow Step Function to start Glue crawler"
  policy      = jsonencode({
    Version = "2012-10-17",
    Statement = [
      {
        Effect = "Allow",
        Action = [
          "glue:StartCrawler"
        ],
        Resource = "arn:aws:glue:ap-northeast-1:879363564916:crawler/youtube_processed_data_crawler"
      },
      {
        Effect = "Allow",
        Action = [
          "logs:CreateLogStream",
          "logs:PutLogEvents"
        ],
        Resource = "arn:aws:logs:ap-northeast-1:879363564916:log-group:/prd/data-pipeline/sfn-executions:*" 
      }
    ]
  })
}

# SFNがCrawlerをスタートするポリシーをモジュールにアタッチ
resource "aws_iam_role_policy_attachment" "attach_glue_startcrawler" {
  role       = module.step-function.role_name
  policy_arn = aws_iam_policy.startcrawler_cloudwatch_policy.arn
}

# SFNの定義
module "step-function" {
  source  = "terraform-aws-modules/step-functions/aws"
  version = "5.0.1"

  name       = "youtube-glue-workflow"
  type = "STANDARD"

  definition = <<EOF
{
  "Comment": "A description of my state machine",
  "QueryLanguage": "JSONPath",
  "TimeoutSeconds": 900,
  "StartAt": "Pass",
  "States": {
    "Pass": {
      "Type": "Pass",
      "Parameters": {
        "decoded_payload.$": "$.lambda_output"
      },
      "ResultPath": "$",
      "Next": "RunGlueJobAndWait"
    },
    "RunGlueJobAndWait": {
      "Type": "Task",
      "Resource": "arn:aws:states:::glue:startJobRun.sync",
      "Parameters": {
        "JobName": "${aws_glue_job.youtube_data_processing_job.name}",
        "Arguments": {
          "--artist_name_slug.$": "$.decoded_payload.artist_name_slug",
          "--correlation_id.$": "$.decoded_payload.correlation_id",
          "--s3_input_path_comment.$": "$.decoded_payload.input_keys[2]",
          "--processed_base_path.$": "$.decoded_payload.processed_base_path",
          "--report_base_path.$": "$.decoded_payload.report_base_path",
          "--s3_input_path_channel.$": "$.decoded_payload.input_keys[0]",
          "--s3_input_path_video.$": "$.decoded_payload.input_keys[1]"
        }
      },
      "ResultPath": "$.glue_result",
      "Retry": [
        {
          "ErrorEquals": [
            "States.TaskFailed"
          ],
          "IntervalSeconds": 30,
          "MaxAttempts": 3,
          "BackoffRate": 2
        }
      ],
      "Catch": [
        {
          "ErrorEquals": [
            "States.ALL"
          ],
          "ResultPath": "$.ErrorDetails",
          "Next": "Lambda Invoke"
        }
      ],
      "Next": "StartCrawler",
      "TimeoutSeconds": 450
    },
    "Lambda Invoke": {
      "Type": "Task",
      "Resource": "arn:aws:states:::lambda:invoke",
      "OutputPath": "$.Payload",
      "Parameters": {
        "Payload.$": "$",
        "FunctionName": "${module.lambda_clean_back.lambda_function_arn}"
      },
      "Retry": [
        {
          "ErrorEquals": [
            "Lambda.ServiceException",
            "Lambda.AWSLambdaException",
            "Lambda.SdkClientException",
            "Lambda.TooManyRequestsException"
          ],
          "IntervalSeconds": 1,
          "MaxAttempts": 3,
          "BackoffRate": 2,
          "JitterStrategy": "FULL"
        }
      ],
      "Next": "NotifyFailure"
    },
    "StartCrawler": {
      "Type": "Task",
      "Parameters": {
        "Name": "${aws_glue_crawler.youtube_processed_data_crawler.name}"
      },
      "ResultPath": "$.crawler_result",
      "Resource": "arn:aws:states:::aws-sdk:glue:startCrawler",
      "Next": "NotifySuccess",
      "Retry": [
        {
          "ErrorEquals": [
            "States.TaskFailed"
          ],
          "IntervalSeconds": 30,
          "MaxAttempts": 3,
          "BackoffRate": 2
        }
      ],
      "Catch": [
        {
          "ErrorEquals": [
            "States.ALL"
          ],
          "Next": "NotifyFailure",
          "Comment": "Crawler Failure"
        }
      ],
      "TimeoutSeconds": 450
    },
    "NotifySuccess": { 
      "Type": "Task",
      "Resource": "arn:aws:states:::sns:publish",
      "Parameters": {
        "TopicArn": "${aws_sns_topic.alert_topic_sfn.arn}", 
        "Message.$": "States.Format('ETL Pipeline SUCCESS ID: {}', $.decoded_payload.correlation_id)",
        "MessageAttributes": {
          "Status": {
            "DataType": "String",
            "StringValue": "SUCCESS"
          }
        }
      },
      "Next": "Success"
    },
    "NotifyFailure": {
      "Type": "Task",
      "Resource": "arn:aws:states:::sns:publish",
      "Parameters": {
        "TopicArn": "${aws_sns_topic.alert_topic_sfn.arn}",
        "Message.$": "States.Format('ETL Pipeline FAILED for ID: {}. Error: {}', $.decoded_payload.correlation_id, $.ErrorDetails.Cause)",
        "MessageAttributes": {
          "Status": {
            "DataType": "String",
            "StringValue": "FAILED"
          }
        }
      },
      "End": true
    },
    "Success": {
      "Type": "Succeed"
    }
  }
}
EOF
  cloudwatch_log_group_name = "/aws/sfn/youtube-pipeline-executions"
  cloudwatch_log_group_retention_in_days = var.cloudwatch_log_group_retention_in_days

  service_integrations = {
    glue_Sync = {
      glue = [aws_glue_job.youtube_data_processing_job.arn]
    }
    sns = {
      sns = [aws_sns_topic.alert_topic_sfn.arn]
    }
    lambda = {
      lambda = [module.lambda_clean_back.lambda_function_arn]
    }
  }

  logging_configuration = {
    include_execution_data = true 
    level                  = "ALL"
  }

  tags = var.project_tags
}

/*
 * SFN自体のアラーム
 */
# SFNの実行失敗を検知するアラーム
module "sfn_execution_failure_alarm" {
  source              = "terraform-aws-modules/cloudwatch/aws//modules/metric-alarm"
  version             = "5.7.2"

  alarm_name          = "sfn-execution-failed-alarm"
  alarm_description   = "SFNワークフローの実行が失敗しました。Catchブロックで処理されないシステムエラーなどを検知。"
  comparison_operator = "GreaterThanThreshold"
  evaluation_periods  = 1
  threshold           = 0
  period              = 600
  statistic           = "Sum"
  
  metric_name = "ExecutionsFailed"
  namespace   = "AWS/States"

  dimensions = { 
    StateMachineName = module.step-function.state_machine_name
  }

  treat_missing_data = "notBreaching"

  alarm_actions = [aws_sns_topic.alert_topic_sfn.arn]
}

/*
 * Lambda、SFN間のEventBridgeの定義
 */
locals {
  # EventBridgeがSFNに渡すための入力トランスフォーマーを定義
  sfn_input_transformer = {
    input_paths = {
      lambda_output = "$.detail"
    }
    input_template = <<EOT
      {
        "lambda_output": <lambda_output>
      }
    EOT
  }
}

/*
 * EventBridgeの設定
 */
module "eventbridge" {
  source  = "terraform-aws-modules/eventbridge/aws"
  version = "4.2.1"

  bus_name = "youtube-pipeline-event-bus"

  # スケジュールベースの Lambda 実行設定 (最初のブロックの内容)
  # Lambdaへの実行権限をモジュールに自動で設定させる
  attach_lambda_policy = true 
  lambda_target_arns   = [module.youtube_scraper_channel.lambda_arn]

  schedules = {
    sukima_schedule = {
      description         = "Lambda trigger schedule for Channel Sukima-Switch"
      schedule_expression = "cron(0 6 ? * FRI *)"
      timezone            = "Asia/Tokyo"
      arn                 = module.youtube_scraper_channel.lambda_arn 
      input = jsonencode({
        ARTIST_NAME_SLUG = "sukima-switch",
        ARTIST_NAME_DISPLAY = "スキマスイッチ",
        CHANNEL_ID              = "UCCPkJMeZHhxKck-EptqQbBA",
        POWERTOOLS_LOG_LEVEL    = "INFO",
        POWERTOOLS_SERVICE_NAME = "youtube_logger_tools_sukima-switch"
      })
      retry_policy = {
        maximum_retry_attempts = 2
        maximum_event_age_in_seconds = 300
      }
      log_config = {
        include_detail = "FULL"
        level          = "ERROR"
      }
      log_delivery = {
        cloudwatch_logs = {
          destination_arn = aws_cloudwatch_log_group.scheduler_logs.arn
        }
      }
    }

    ikimono_schedule = {
      description         = "Lambda trigger schedule for Channel Ikimono-Gakari"
      schedule_expression = "cron(0 6 ? * MON *)"
      timezone            = "Asia/Tokyo"
      arn                 = module.youtube_scraper_channel.lambda_arn 
      input = jsonencode({
        ARTIST_NAME_SLUG = "ikimonogakari",
        ARTIST_NAME_DISPLAY = "いきものがかり",
        CHANNEL_ID              = "UCflAJoghlGeSkdz5eNIl-sg",
        POWERTOOLS_LOG_LEVEL    = "INFO",
        POWERTOOLS_SERVICE_NAME = "youtube_logger_tools_ikimono-gakari"
      })
      retry_policy = {
        maximum_retry_attempts = 2
        maximum_event_age_in_seconds = 300
      }
      log_config = {
        include_detail = "FULL"
        level          = "ERROR"
      }
      log_delivery = {
        cloudwatch_logs = {
          destination_arn = aws_cloudwatch_log_group.scheduler_logs.arn
        }
      }
    }
  }

  # イベントパターンベースの SFN 起動設定 (2つ目のブロックの内容)
  attach_sfn_policy = true
  sfn_target_arns   = [module.step-function.state_machine_arn]
  
  rules = {
    scraper_completed_event = {
      description = "Lambdaのスクレイピング完了イベントを捕捉し、SFNを起動"
      event_pattern = jsonencode({ 
        "detail-type": ["ScrapingCompleted"],
        "source": ["my-scraper"]
      })
      enabled = true
    }
  }

  targets = {
    scraper_completed_event = [
      {
        name              = "start-sfn-workflow"
        arn               = module.step-function.state_machine_arn # SFNのARNを参照
        attach_role_arn = true
        input_transformer = local.sfn_input_transformer
        dead_letter_arn = module.youtube_event_dlq.queue_arn
        retry_policy = {
            maximum_retry_attempts = 2
            maximum_event_age_in_seconds = 600
        }
      }
    ]
  }

  tags = var.project_tags
}

/*
 * スケジューラー自体に対するアラームの設定
 */
module "scheduler_failure_alarm" {
  source              = "terraform-aws-modules/cloudwatch/aws//modules/metric-alarm"
  version             = "5.7.2"

  alarm_name          = "scheduler-failed-alert"
  alarm_description   = "EventBridge SchedulerがLambdaの呼び出しに失敗し、パイプラインが起動できませんでした。"
  comparison_operator = "GreaterThanThreshold"
  evaluation_periods  = 1
  threshold           = 0
  period              = 600
  statistic           = "Sum"
  
  metric_name = "FailedInvocations"
  namespace   = "AWS/Scheduler"

  treat_missing_data = "notBreaching"

  alarm_actions = [aws_sns_topic.alert_topic_sfn.arn]
}

/*
 * スケジューラーのロググループの設定
 */
resource "aws_cloudwatch_log_group" "scheduler_logs" {
  name              = "/aws/events/scheduler/youtube-pipeline-schedules"
  retention_in_days = var.cloudwatch_log_group_retention_in_days
}

/*
 * Glueジョブスクリプト保存用のS3バケットの作成
 */
resource "aws_s3_bucket" "s3_glue_script_bucket" {
  bucket = var.script_bucket_name
  tags = var.project_tags
  force_destroy = true
}

resource "aws_s3_bucket_public_access_block" "s3_glue_script_block" {
  bucket                  = aws_s3_bucket.s3_glue_script_bucket.id
  block_public_acls       = true
  block_public_policy     = true
  ignore_public_acls      = true
  restrict_public_buckets = true
}

/*
 * Glueの設定
 */
# glueが使用するBQの認証キーをSecretMangerへ設定（後で手動で入力）
module "bigquery_secret" {
  source = "terraform-aws-modules/secrets-manager/aws"
  version = "2.0.0"

  name_prefix             = "project-youtube-bigquery-secret-key"
  description             = "BigQuery service account key for project-youtube"
  recovery_window_in_days = 14
  create_random_password = false 
  secret_string = var.bigquery_sa_key_json
  create_policy = false
}

# Glue Connectionを定義
resource "aws_glue_connection" "bigquery_connection" {
  name            = "bigquery-connector-spark-connection"
  description     = "AWS Glue BigQuery Connection using SparkProperties."
  
  connection_type = "BIGQUERY" 

  connection_properties = {
    SparkProperties = jsonencode({
      secretId = module.bigquery_secret.secret_name
    })
  }
}

# GlueのIAMロールの定義
resource "aws_iam_role" "glue_job_execution_role" {
  name_prefix        = "glue-youtube-job-role"
  description        = "IAM role for AWS Glue Job to access S3, Secrets Manager, and Data Catalog."
  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Effect    = "Allow"
        Principal = {
          Service = "glue.amazonaws.com"
        }
        Action = "sts:AssumeRole"
      }
    ]
  })
}

# Glueジョブのポリシー設定
resource "aws_iam_policy" "glue_combined_policy" {
  name_prefix = "glue-youtube-job-combined-policy"

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      # S3とSecret Managerへのアクセス
      {
        Sid    = "DataAccessAndSecrets",
        Effect = "Allow",
        Action = [
          "secretsmanager:GetSecretValue",
          "s3:GetObject",
          "s3:PutObject",
          "s3:DeleteObject"
        ],
        Resource = [
          module.bigquery_secret.secret_arn,
          "${aws_s3_bucket.s3_data_lake_bucket.arn}/*",
          "${aws_s3_bucket.s3_glue_script_bucket.arn}/*"
        ]
      },

      # S3 ListBucket権限
      {
        Sid    = "ListS3Buckets",
        Effect = "Allow",
        Action = [
          "s3:ListBucket"
        ],
        Resource = [
          aws_s3_bucket.s3_data_lake_bucket.arn,
          aws_s3_bucket.s3_glue_script_bucket.arn
        ]
      },

      # GlueカタログとCloudWatch Logs権限
      {
        Sid    = "GlueCatalogAndLogs",
        Effect = "Allow",
        Action = [
          "glue:GetDatabase",
          "glue:CreateTable",
          "glue:UpdateTable",
          "glue:GetTable",
          "glue:DeleteTable",
          "glue:GetTableVersions",
          "glue:GetPartitions",
          "glue:UpdatePartition",
          "glue:CreatePartition",
          "glue:BatchCreatePartition",
          
          "logs:CreateLogGroup",
          "logs:CreateLogStream",
          "logs:PutLogEvents",
          
          "iam:PassRole" 
        ],
        Resource = "*" 
      },
      
      # Glueサービス固有権限
      {
        Sid    = "GlueServiceWideAccess",
        Effect = "Allow",
        Action = [
          "glue:*"
        ],
        Resource = "*"
      }
    ]
  })
}

resource "aws_iam_role_policy_attachment" "glue_combined_attach" {
  role       = aws_iam_role.glue_job_execution_role.name
  policy_arn = aws_iam_policy.glue_combined_policy.arn
}

# Glueのロググループの作成
resource "aws_cloudwatch_log_group" "glue_etl_logs" {
  name              = "/aws-glue/jobs/youtube-data-processing-job"
  retention_in_days = var.cloudwatch_log_group_retention_in_days
}

# Glueジョブの定義
resource "aws_glue_job" "youtube_data_processing_job" {
  name             = "youtube-data-processing-job"
  description      = "Processes YouTube raw data and loads to the Data Catalog using BigQuery Connection."
  role_arn         = aws_iam_role.glue_job_execution_role.arn 
  glue_version     = "5.0"
  max_retries      = 2
  timeout          = 20
  number_of_workers = 2
  worker_type      = "G.1X"
  
  connections      = [aws_glue_connection.bigquery_connection.name]
  execution_class  = "STANDARD"

  command {
    script_location = "s3://${aws_s3_bucket.s3_glue_script_bucket.id}/jobs/youtube_processor.py"
    name            = "glueetl"
    python_version  = "3"
  }
  
  # Spark UI LogsとTemporary Pathの設定を追加
  default_arguments = {
    "--TempDir"                 = "s3://${aws_s3_bucket.s3_glue_script_bucket.id}/tmp/"
    "--spark-event-logs-path"   = "s3://${aws_s3_bucket.s3_data_lake_bucket.id}/logs/spark-ui/"
    "--enable-spark-ui"         = "true"
    "--job-language"            = "python"
    "--enable-continuous-cloudwatch-log" = "true"
    "--continuous-log-logGroup" = aws_cloudwatch_log_group.glue_etl_logs.name
    "--enable-continuous-log-filter"     = "true"
    "--enable-metrics"          = ""
    "--enable-auto-scaling"     = "true"
    "--gcp_project_id" = "project-youtube-472803"
    "--bq_dataset" = "youtube_project_processed_data"
  }
}

/*
 * クローラーとデータカタログの定義
 */
resource "aws_glue_catalog_database" "crawler_db" {
  name = var.glue_database_name
}

resource "aws_glue_crawler" "youtube_processed_data_crawler" {
  database_name = aws_glue_catalog_database.crawler_db.name
  name          = "youtube_processed_data_crawler"
  role          = aws_iam_role.glue_job_execution_role.arn

  s3_target {
    path = "s3://${var.data_bucket_name}"
  }
}

/*
 * SNSの定義
 */
 # トピックの定義
resource "aws_sns_topic" "alert_topic_sfn" {
  name = "youtube-etl-alert-topic" 
}

# Eメールサブスクリプションの定義
resource "aws_sns_topic_subscription" "alert_email_subscription" {
  topic_arn = aws_sns_topic.alert_topic_sfn.arn
  protocol  = "email"
  endpoint  = var.alert_email_endpoint 
}

/*
 * BigQueryの定義
 */
# BQデータセットの定義
resource "google_bigquery_dataset" "bq_data_set" {
  dataset_id                  = "youtube_project_processed_data"
  friendly_name               = "Processed Data for YouTube Project"
  description                 = "AWS Glueからの加工データを受け取るためのデータセット"
  location                    = var.gcp_region
  project = var.gcp_project_id
  delete_contents_on_destroy = true # 注意：破壊用に一時的に設定
}

# BQスキーマの定義
locals {
  schema_channel = [
    { name = "published_at", type = "TIMESTAMP", mode = "REQUIRED" },
    { name = "video_count", type = "INTEGER", mode = "NULLABLE" },
    { name = "total_views", type = "INTEGER", mode = "NULLABLE" },
    { name = "channel_id", type = "STRING", mode = "REQUIRED" },
    { name = "subscriber_count", type = "INTEGER", mode = "NULLABLE" },
    { name = "channel_name", type = "STRING", mode = "NULLABLE" }
  ]
  schema_video = [
    { name = "video_id", type = "STRING", mode = "REQUIRED" },
    { name = "title", type = "STRING", mode = "NULLABLE" },
    { name = "published_at", type = "TIMESTAMP", mode = "REQUIRED" },
    { name = "view_count", type = "INTEGER", mode = "NULLABLE" },
    { name = "like_count", type = "INTEGER", mode = "NULLABLE" },
    { name = "comment_count", type = "INTEGER", mode = "NULLABLE" },
    { name = "duration", type = "STRING", mode = "NULLABLE" },
    { name = "tags", type = "STRING", mode = "NULLABLE" },
    { name = "total_seconds", type = "INTEGER", mode = "NULLABLE" }
  ]
  schema_comment = [
    { name = "video_id", type = "STRING", mode = "NULLABLE" },
    { name = "comment_id", type = "STRING", mode = "REQUIRED" },
    { name = "author_display_name", type = "STRING", mode = "NULLABLE" },
    { name = "published_at", type = "TIMESTAMP", mode = "REQUIRED" },
    { name = "text_display", type = "STRING", mode = "NULLABLE" },
    { name = "like_count", type = "INTEGER", mode = "NULLABLE" }
  ]
}

# BQスキーマに対応するテーブルの定義
locals {
  table_schema_map = {
    sukima-switch_channel = local.schema_channel
    sukima-switch_video = local.schema_video
    sukima-switch_comment = local.schema_comment
    ikimonogakari_channel = local.schema_channel
    ikimonogakari_video = local.schema_video
    ikimonogakari_comment = local.schema_comment
    spitz_channel = local.schema_channel
    spitz_video = local.schema_video
    spitz_comment = local.schema_comment
  }
}

# BQテーブルの定義
resource "google_bigquery_table" "bq_data_table" {
  project = var.gcp_project_id
  dataset_id = google_bigquery_dataset.bq_data_set.dataset_id

  for_each = local.table_schema_map
  table_id   = each.key
  deletion_protection = false # 注意：destroy用に設定にしているので後で変更
  time_partitioning {
    type = "DAY"
  }

  schema     = jsonencode(each.value)
}
 
/*
 * EventBridgeのエラーを受け取るSQSの定義
 */
module "youtube_event_dlq" {
  source  = "terraform-aws-modules/sqs/aws"
  version = "5.1.0"

  name = "youtube_event_dlq"
  create_queue_policy = true

  queue_policy_statements = {
    eventbridge_send = {
      sid     = "AllowEventBridgeToSendMessages"
      actions = ["sqs:SendMessage"]

      principals = [
        {
          type        = "Service"
          identifiers = ["events.amazonaws.com"]
        }
      ]

      condition = [{
        test     = "ForAllValues:ArnEquals" 
        variable = "aws:SourceArn"
        values   = [module.eventbridge.eventbridge_rule_arns.scraper_completed_event]
      }]
    }
  }
}

/*
 * SQSを受け取るCloudWatchアラームの定義
 */
module "dlq_event_alarm" {
  source  = "terraform-aws-modules/cloudwatch/aws//modules/metric-alarm"
  version = "5.7.2"

  alarm_name          = "dlq-eventbridge-Alarm"
  comparison_operator = "GreaterThanThreshold"
  evaluation_periods  = 1
  threshold           = 0
  period              = 600
  statistic           = "Sum"
  
  metric_name = "ApproximateNumberOfMessagesVisible"
  namespace   = "AWS/SQS"
  
  dimensions = { 
    QueueName = module.youtube_event_dlq.queue_name
  }

  alarm_actions = [aws_sns_topic.alert_topic_sfn.arn]
}

module "lambda_clean_back" {
  source = "terraform-aws-modules/lambda/aws"

  function_name = "youtube_clean_back_function"
  description   = "ワークフローが途中で止まった際にクリーンバックします。"
  handler       = "clean_up_lambda.lambda_handler"
  runtime       = "python3.12"
  source_path = "../src/clean_up"
  tags = var.project_tags

  create_role = true

  attach_cloudwatch_logs_policy = true
  attach_create_log_group_permission = true

  attach_policy_json = true
  policy_json = jsonencode({
    Version = "2012-10-17",
    Statement = [
      {
        Effect = "Allow",
        Action = [
          "s3:GetObject",
          "s3:GetObjectAcl",
          "s3:ListBucket",
          "s3:DeleteObject"
        ],
        Resource = [
          "arn:aws:s3:::${var.data_bucket_name}",
          "arn:aws:s3:::${var.data_bucket_name}/*"
        ]
      }
      # Glue パーティション削除権限 (Glueカタログのクリーンアップを行う場合)
      # {
      #   Effect = "Allow",
      #   Action = [
      #     "glue:DeletePartition"
      #   ],
      #   Resource = "*"
      # }
    ]
  })
}
