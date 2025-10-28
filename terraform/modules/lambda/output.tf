output "lambda_arn" {
  description = "The ARN of the created Lambda function."
  value       = aws_lambda_function.scraper.arn
}

output "lambda_name" {
  description = "The name of the created Lambda function."
  value       = aws_lambda_function.scraper.function_name
}

output "execution_role_arn" {
  description = "The ARN of the Lambda execution IAM role."
  value       = aws_iam_role.execution_role.arn
}