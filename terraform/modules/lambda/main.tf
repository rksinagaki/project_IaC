/*
 * Lambdaのassume role作成
 */
resource "aws_iam_role" "execution_role" {
  name = "${var.function_name}-role"

  assume_role_policy = jsonencode({
    Version = "2012-10-17",
    Statement = [{
      Action = "sts:AssumeRole",
      Effect = "Allow",
      Principal = {
        Service = "lambda.amazonaws.com"
      }
    }]
  })

  tags = var.project_tags
}

/*
 * Lambdaのポリシー設定
 */
resource "aws_iam_policy" "combined_execution_policy" {
  name        = "${var.function_name}-policy"
  description = "Execution policy for ${var.function_name}"

  policy = jsonencode({
    Version = "2012-10-17",
    Statement = [
      # CloudWatch Logsへの書き込み権限
      {
        Sid      = "CloudWatchLogsAccess",
        Effect   = "Allow",
        Action   = [
          "logs:CreateLogGroup",
          "logs:CreateLogStream",
          "logs:PutLogEvents",
        ],
        Resource = "arn:aws:logs:${var.region_name}:*:*"
      },

      # S3データレイクへのアクセス権限
      {
        Sid      = "S3DataLakeAccess",
        Effect   = "Allow",
        Action   = [
          "s3:PutObject",
          "s3:GetObject",
          "s3:ListBucket"
        ],
        Resource = [
          "arn:aws:s3:::${var.s3_data_lake_bucket_name}",
          "arn:aws:s3:::${var.s3_data_lake_bucket_name}/*"
        ]
      },

      # Secret Managerへの読み取り権限
      {
        Sid      = "SecretsManagerRead",
        Effect   = "Allow",
        Action   = [
          "secretsmanager:GetSecretValue",
          "secretsmanager:DescribeSecret"
        ],
        Resource = var.youtube_secret_arn
      },

      # EventBridgeへの引継ぎ権限
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
resource "aws_iam_role_policy_attachment" "combined_attach" {
  role       = aws_iam_role.execution_role.name
  policy_arn = aws_iam_policy.combined_execution_policy.arn
}

/*
 * Lambdaの定義
 */
resource "aws_lambda_function" "scraper" {
  function_name = var.function_name
  description   = "Scrape youtube data with Google API."
  package_type  = "Image"

  image_uri     = "${var.ecr_repository_url}:latest" 
  role          = aws_iam_role.execution_role.arn

  image_config {
    command = ["app_lambda.lambda_handler"]
  }

  environment {
    variables = {
      BUCKET_NAME           = var.s3_data_lake_bucket_name
      REGION_NAME           = var.region_name
      YOUTUBE_API_KEY_ARN   = var.youtube_secret_arn
    }
  }

  timeout     = 300 
  memory_size = 256
}

/*
 * CloudWatch Log Groupの定義（モジュールに含める）
 */
resource "aws_cloudwatch_log_group" "log_group" {
  name              = "/aws/lambda/${var.function_name}"
  retention_in_days = 30 
}