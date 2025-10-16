/*
 * S3データレイクバケットの作成
 */
resource "aws_s3_bucket" "s3_data_lake_bucket" {
  bucket = var.data_bucket_name

  tags = var.project_tags
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
resource "aws_iam_role" "lambda_exec_role" {
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
  role       = aws_iam_role.lambda_exec_role.name
  policy_arn = aws_iam_policy.lambda_s3_policy.arn
}