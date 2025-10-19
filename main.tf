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
 * YouTubeAPI実行lambdaの信頼関係の設定(roleの作成)
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
 * YouTubeAPI実行lambdaのアクセス権限ポリシー
 */
resource "aws_iam_policy" "lambda_s3_policy" {
  name        = "youtube-pipeline-lambda-access-policy"
  description = "LambdaのS3への読み書き、ログの書き込み権限のポリシー"

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      # CloudWatch Logsへの書き込み権限
      {
        Action = [
          "logs:CreateLogGroup",
          "logs:CreateLogStream",
          "logs:PutLogEvents",
        ]
        Effect   = "Allow"
        Resource = "arn:aws:logs:*:*:*"
      },
      # S3データレイクへのアクセス権限
      {
        Action = [
          "s3:PutObject",
          "s3:GetObject",
          "s3:ListBucket"
        ]
        Effect   = "Allow"
        # bucketとbucket内のリソースを指定
        Resource = [
          aws_s3_bucket.s3_data_lake_bucket.arn,
          "${aws_s3_bucket.s3_data_lake_bucket.arn}/*" 
        ]
      },
    ]
  })
}

/*
 * ロールとポリシーの紐づけ
 */
resource "aws_iam_role_policy_attachment" "lambda_s3_attach" {
  role       = aws_iam_role.lambda_execution_role.name
  policy_arn = aws_iam_policy.lambda_s3_policy.arn
}

/*
 * EventBridgeの設定
 */
module "eventbridge" {
  source  = "terraform-aws-modules/eventbridge/aws"
  version = "4.2.1"

  bus_name = "youtube-pipeline-event-bus" 

  # ----------------------------------------------------
  # A. スケジュールベースの Lambda 実行設定 (最初のブロックの内容)
  # ----------------------------------------------------  
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
        CHANNEL_ID              = "UCflAJoghlGeSkdz5eNIl-sg",
        POWERTOOLS_LOG_LEVEL    = "INFO",
        POWERTOOLS_SERVICE_NAME = "youtube_logger_tools_ikimono-gakari"
      })
    }
  }
  # ----------------------------------------------------
  # B. イベントパターンベースの SFN 起動設定 (2つ目のブロックの内容)
  # ----------------------------------------------------
  rules = {
    scraper_completed_event = { # 名前を区別しやすいように変更
      description = "Lambdaのスクレイピング完了イベントを捕捉し、SFNを起動"
      event_pattern = jsonencode({ 
        "source" : ["my-scraper"],            
        "detail-type": ["ScrapingCompleted"]
      })
      enabled = true
    }
  }

  targets = {
    scraper_completed_event = [ # ルール名とキー名を一致させる
      {
        name              = "start-sfn-workflow"
        arn               = module.step-function.state_machine_arn # SFNのARNを参照
        role_arn          = aws_iam_role.eventbridge_invoke_sfn.arn
        input_transformer = local.sfn_input_transformer
      }
    ]
  }
  # attach_sfn_policy = true
  # sfn_target_arns   = [module.step-function.state_machine_arn]

  tags = var.project_tags
}

resource "aws_iam_role" "eventbridge_invoke_sfn" {
  name = "eventbridge-invoke-sfn-role"

  assume_role_policy = jsonencode({
    Version = "2012-10-17",
    Statement = [{
      Effect = "Allow",
      Principal = {
        Service = "events.amazonaws.com"
      },
      Action = "sts:AssumeRole"
    }]
  })
}

resource "aws_iam_role_policy" "eventbridge_invoke_sfn_policy" {
  role = aws_iam_role.eventbridge_invoke_sfn.id

  policy = jsonencode({
    Version = "2012-10-17",
    Statement = [{
      Effect = "Allow",
      Action = [
        "states:StartExecution"
      ],
      Resource = module.step-function.state_machine_arn
    }]
  })
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
 * Secret managerの定義(API Keyは手動で設定)
 */
# data blockで現在のアカウントIDを取得
data "aws_caller_identity" "current" {}

# 1. Secrets Manager モジュールを使ってシークレットの枠組みとポリシーを作成
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

resource "aws_iam_policy" "lambda_secret_read_policy" {
  name        = "lambda-secret-read_policy"
  policy      = jsonencode({
    Version = "2012-10-17",
    Statement = [
      {
        Effect = "Allow",
        Action = [
          "secretsmanager:GetSecretValue",
          "secretsmanager:DescribeSecret"
        ],
        Resource = module.youtube_secret.secret_arn
      }
    ]
  })
}

# 作成したlambda_secret_read_policyをlambda_execution_roleへアタッチ
resource "aws_iam_role_policy_attachment" "lambda_secret_read_attach" {
  role       = aws_iam_role.lambda_execution_role.name 
  policy_arn = aws_iam_policy.lambda_secret_read_policy.arn
}

/*
 * Glueジョブを仮で定義
 */
locals {
  glue_job_name = "youtube-transformer-job" 
  glue_job_arn  = "arn:aws:glue:${var.region_name}:${data.aws_caller_identity.current.account_id}:job/${local.glue_job_name}"
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
  "Comment": "Start AWS Glue Job synchronously using S3 key from Lambda input.",
  "StartAt": "RunGlueJob",
  "States": {
    "RunGlueJob": {
      "Type": "Task",
      "Resource": "arn:aws:states:::glue:startJobRun.sync", 
      "Parameters": {
        "JobName": "${local.glue_job_name}",
        "Arguments": {
          "--S3_KEY.$": "$.s3_raw_data_key" 
        }
      },
      "Catch": [
        {
          "ErrorEquals": ["States.All"],
          "Next": "HandleFailure"
        }
      ],
      "End": true
    },
    "HandleFailure": {
      "Type": "Fail",
      "Cause": "Glue Job failed to run."
    }
  }
}
EOF
  service_integrations = {
    glue_Sync = {
      glue = [local.glue_job_arn] 
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

# LambdaのEventBridgeへの書き込みポリシー
resource "aws_iam_policy" "eventbridge_put_events_policy" {
  name        = "eventbridge-put-events-policy"
  description = "Allows Lambda to put custom events to EventBridge."
  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Action   = "events:PutEvents"
        Effect   = "Allow"
        Resource = "*"
      },
    ]
  })
}

# Lambda実行ロールへのポリシーのアタッチ
resource "aws_iam_role_policy_attachment" "lambda_eventbridge_attach" {
  # 既存のLambda実行ロールIDに置き換えてください
  role       = aws_iam_role.lambda_execution_role.name
  policy_arn = aws_iam_policy.eventbridge_put_events_policy.arn
}