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
 * awsリポジトリ(ECR)の定義
 */
resource "aws_ecr_repository" "lambda_ecr_repository" {
  name                 = "youtube-lambda-scraper-repository"
  image_tag_mutability = "MUTABLE"

  image_scanning_configuration {
    scan_on_push = true
  }

  force_delete = true
}

/*
 * Secret managerの定義(API Keyは手動で設定)
 */
data "aws_caller_identity" "current" {}

# Secrets Managerの枠組みとポリシーを作成
module "youtube_secret" {
  source = "terraform-aws-modules/secrets-manager/aws"
  version = "2.0.0"

  name_prefix             = "project-youtube-youtube-api-key"
  description             = "YouTube Data API Key for data scraper"
  recovery_window_in_days = 14
  create_random_password = false 
  secret_string = jsonencode({
    API_KEY = "PLACEHOLDER" # 後で手動で入れる
  })
  create_policy = false
}

/*
 * Lambdaのassume role作成
 */
resource "aws_iam_role" "lambda_execution_role" {
  name = "youtube-pipeline-lambda-role"
  
  assume_role_policy = jsonencode({
    Version = "2012-10-17",
    Statement = [
      {
        Action = "sts:AssumeRole",
        Effect = "Allow",
        Principal = {
          Service = "lambda.amazonaws.com"
        }
      }
    ]
  })

  tags = var.project_tags
}

/*
 * Lambdaのポリシー設定
 */
resource "aws_iam_policy" "lambda_combined_execution_policy" {
  name        = "youtube-pipeline-lambda-combined-policy"
  description = "YouTube API実行Lambdaに必要な全ての権限（Logs, S3, Secrets）"

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      # LambdaのCloudWatch Logsへの書き込み権限
      {
        Sid      = "CloudWatchLogsAccess",
        Effect   = "Allow",
        Action   = [
          "logs:CreateLogGroup",
          "logs:CreateLogStream",
          "logs:PutLogEvents",
        ],
        Resource = "arn:aws:logs:*:*:*"
      },

      # LambdaのS3データレイクへのアクセス権限
      {
        Sid      = "S3DataLakeAccess",
        Effect   = "Allow",
        Action   = [
          "s3:PutObject",
          "s3:GetObject",
          "s3:ListBucket"
        ],
        Resource = [
          aws_s3_bucket.s3_data_lake_bucket.arn,
          "${aws_s3_bucket.s3_data_lake_bucket.arn}/*"
        ]
      },

      # LambdaのSecret Managerへの読み取り権限
      {
        Sid      = "SecretsManagerRead",
        Effect   = "Allow",
        Action   = [
          "secretsmanager:GetSecretValue",
          "secretsmanager:DescribeSecret"
        ],
        Resource = module.youtube_secret.secret_arn
      },

      # LambdaのEventBridgeへの引継ぎ権限
      {
        Sid      = "EventBridgePutEvents",
        Effect   = "Allow",
        Action   = "events:PutEvents",
        Resource = "*"
      }
    ]
  })
}

/*
 * Lambdaのポリシーをロールへアタッチ
 */
resource "aws_iam_role_policy_attachment" "lambda_combined_attach" {
  role       = aws_iam_role.lambda_execution_role.name
  policy_arn = aws_iam_policy.lambda_combined_execution_policy.arn 
}

/*
 * Lambdaの定義
 */
resource "aws_lambda_function" "youtube_lambda_scraper" {
  function_name = "youtube-data-scraper"
  description   = "Scrape youtube data with Google API."
  package_type = "Image"
  
  # dockerイメージのタグはlatestを指定
  image_uri    = "${aws_ecr_repository.lambda_ecr_repository.repository_url}:latest"  
  role         = aws_iam_role.lambda_execution_role.arn
  
  image_config {
    command = ["app_lambda.lambda_handler"]
  }

  environment {
    variables = {
      BUCKET_NAME = var.data_bucket_name
      REGION_NAME = var.region_name
      YOUTUBE_API_KEY_ARN = module.youtube_secret.secret_arn
    }
  }

  timeout      = 300 
  memory_size  = 256
  
  depends_on = [
    aws_ecr_repository.lambda_ecr_repository,
  ]
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

module "step-function" {
  source  = "terraform-aws-modules/step-functions/aws"
  version = "5.0.1"

  name       = "youtube-glue-workflow"
  type = "STANDARD"
  # 後で変更
  definition = <<EOF
{
  "Comment": "A description of my state machine",
  "QueryLanguage": "JSONPath",
  "TimeoutSeconds": 600,
  "StartAt": "Pass",
  "States": {
    "Pass": {
      "Type": "Pass",
      "Parameters": {
        "decoded_payload.$": "States.StringToJson($.input)"
      },
      "ResultPath": "$.decoded_payload",
      "Next": "Glue StartJobRun"
    },
    "Glue StartJobRun": {
      "Type": "Task",
      "Resource": "arn:aws:states:::glue:startJobRun",
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
      "Catch": [
        {
          "ErrorEquals": [
            "States.ALL"
          ],
          "ResultPath": "$.ErrorDetails",
          "Next": "NotifyFailure"
        }
      ],
      "Next": "Success"
    },
    "NotifyFailure": {
      "Type": "Task",
      "Resource": "arn:aws:states:::sns:publish",
      "Parameters": {
        "TopicArn": "${aws_topic_sns.alert_topic_sfn.arn}",
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
  service_integrations = {
    glue_Sync = {
      glue = [aws_glue_job.youtube_data_processing_job.arn]
    }
  }

  tags = var.project_tags
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
    input_template = "<lambda_output>"
  }
}

##### test #####
# debug用ロググループの作成
resource "aws_cloudwatch_log_group" "eventbridge_debug" {
  name              = "/aws/events/youtube-pipeline-event-bus-debug-log"
  retention_in_days = 7
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
  lambda_target_arns   = [aws_lambda_function.youtube_lambda_scraper.arn]

  schedules = {
    sukima_schedule = {
      description         = "Lambda trigger schedule for Channel Sukima-Switch"
      schedule_expression = "cron(0 6 ? * FRI *)"
      timezone            = "Asia/Tokyo"
      arn                 = aws_lambda_function.youtube_lambda_scraper.arn 
      input = jsonencode({
        ARTIST_NAME_SLUG = "sukima-switch",
        ARTIST_NAME_DISPLAY = "スキマスイッチ",
        CHANNEL_ID              = "UCCPkJMeZHhxKck-EptqQbBA",
        POWERTOOLS_LOG_LEVEL    = "INFO",
        POWERTOOLS_SERVICE_NAME = "youtube_logger_tools_sukima-switch"
      })
    }
    ikimono_schedule = {
      description         = "Lambda trigger schedule for Channel Ikimono-Gakari"
      schedule_expression = "cron(0 6 ? * MON *)"
      timezone            = "Asia/Tokyo"
      arn                 = aws_lambda_function.youtube_lambda_scraper.arn 
      input = jsonencode({
        ARTIST_NAME_SLUG = "ikimonogakari",
        ARTIST_NAME_DISPLAY = "いきものがかり",
        CHANNEL_ID              = "UCflAJoghlGeSkdz5eNIl-sg",
        POWERTOOLS_LOG_LEVEL    = "INFO",
        POWERTOOLS_SERVICE_NAME = "youtube_logger_tools_ikimono-gakari"
      })
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
    scraper_completed_event = [ # ルール名とキー名を一致させる
      {
        name              = "start-sfn-workflow"
        arn               = module.step-function.state_machine_arn # SFNのARNを参照
        attach_role_arn = true
        input_transformer = local.sfn_input_transformer
      }
    ]
  }

  tags = var.project_tags
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
  secret_string = jsonencode({
    "type": "PLACEHOLDER",
    "project_id": "PLACEHOLDER",
    "private_key_id": "PLACEHOLDER",
    "private_key": "PLACEHOLDER",
    "client_email": "PLACEHOLDER",
    "client_id": "PLACEHOLDER",
    "auth_uri": "PLACEHOLDER",
    "token_uri": "PLACEHOLDER",
    "auth_provider_x509_cert_url": "PLACEHOLDER",
    "client_x509_cert_url": "PLACEHOLDER",
    "universe_domain": "PLACEHOLDER"
  })
  create_policy = false #　後で作る
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

# Glueジョブの定義
resource "aws_glue_job" "youtube_data_processing_job" {
  name             = "youtube-data-processing-job"
  description      = "Processes YouTube raw data and loads to the Data Catalog using BigQuery Connection."
  role_arn         = aws_iam_role.glue_job_execution_role.arn 
  glue_version     = "5.0"
  max_retries      = 0
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
    "--spark-ui-log-path"       = "s3://${aws_s3_bucket.s3_glue_script_bucket.id}/logs/spark-ui/"
    "--enable-spark-ui"         = "true"
    
    "--job-language"            = "python"
    "--continuous-log-logGroup" = "/aws-glue/jobs"
    "--enable-continuous-cloudwatch-log" = "true"
    "--enable-continuous-log-filter"     = "true"
    "--enable-metrics"          = "true"
    "--enable-auto-scaling"     = "true"
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
  deletion_protection = true
  time_partitioning {
    type = "DAY"
  }

  schema     = jsonencode(each.value)
}
 