output "function_urls" {
  description = "Lambda Function URLs. Sensitive — endpoints with authorization_type=NONE are public."
  value       = { for k, u in aws_lambda_function_url.this : k => u.function_url }
  sensitive   = true
}

output "role_arn" {
  description = "Shared Lambda execution role ARN."
  value       = aws_iam_role.lambda_exec.arn
}
