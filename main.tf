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
  bus_name = "youtube-pipeline-event-scheduler"

  attach_lambda_policy = true
  lambda_target_arns = [aws_lambda_function.youtube_lambda_scraper.arn]

  schedules = {
    sukima_schedule = {
      description = "Lambda trigger schedule for Channel Sukima-Switch"
      schedule_expression = "cron(0 6 ? * FRI *)"
      timezone = "Asia/Tokyo"
      arn = aws_lambda_function.youtube_lambda_scraper.arn # my_lambda_functionは後で変更
      input = jsonencode({
        CHANNEL_ID = "UCCPkJMeZHhxKck-EptqQbBA",
        POWERTOOLS_LOG_LEVEL    = "INFO",
        POWERTOOLS_SERVICE_NAME = "youtube_logger_tools_sukima-switch"
      })
    }

    ikimono_schedule = {
      description = "Lambda trigger schedule for Channel Ikimono-Gakari"
      schedule_expression = "cron(0 6 ? * MON *)"
      timezone = "Asia/Tokyo"
      arn = aws_lambda_function.youtube_lambda_scraper.arn # my_lambda_functionは後で変更
      input = jsonencode({
        CHANNEL_ID = "UCflAJoghlGeSkdz5eNIl-sg",
        POWERTOOLS_LOG_LEVEL    = "INFO",
        POWERTOOLS_SERVICE_NAME = "youtube_logger_tools_ikimono-gakari"
      })
    }
  }
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

# secret managerモジュールで作成したポリシーをlambda_execution_roleへアタッチ
resource "aws_iam_role_policy_attachment" "lambda_secret_read_attach" {
  role       = aws_iam_role.lambda_execution_role.name 
  policy_arn = aws_iam_policy.lambda_secret_read_policy.arn
}