data "aws_iam_policy_document" "assume" {
  statement {
    actions = ["sts:AssumeRole"]
    principals {
      type        = "Service"
      identifiers = ["lambda.amazonaws.com"]
    }
  }
}

# Shared exec role — created only when some function doesn't bring its own role_arn.
# The live functions all use pre-existing per-function roles (referenced by ARN,
# not managed here — adopting them is a separate step).
locals {
  functions_on_shared_role = {
    for k, f in var.functions : k => f
    if f.role_arn == null && !contains(keys(local.function_roles), k)
  }
}

resource "aws_iam_role" "lambda_exec" {
  count = length(local.functions_on_shared_role) > 0 ? 1 : 0

  name               = "${var.name_prefix}-lambda-exec"
  assume_role_policy = data.aws_iam_policy_document.assume.json
}

resource "aws_iam_role_policy_attachment" "basic" {
  count = length(local.functions_on_shared_role) > 0 ? 1 : 0

  role       = aws_iam_role.lambda_exec[0].name
  policy_arn = "arn:aws:iam::aws:policy/service-role/AWSLambdaBasicExecutionRole"
}

resource "aws_lambda_function" "this" {
  for_each = var.functions

  function_name = each.key
  role = coalesce(
    each.value.role_arn,
    try(aws_iam_role.per_function[each.key].arn, null),
    one(aws_iam_role.lambda_exec[*].arn),
  )
  runtime     = each.value.runtime
  handler     = each.value.handler
  s3_bucket   = each.value.s3_bucket
  s3_key      = each.value.s3_key
  memory_size = each.value.memory_size
  timeout     = each.value.timeout

  dynamic "environment" {
    for_each = length(each.value.env) > 0 ? [1] : []
    content {
      variables = each.value.env
    }
  }

  # Application code is shipped by a separate pipeline and runtime secrets
  # (e.g. RELAY_TOKEN) live in the function config; Terraform owns the rest.
  lifecycle {
    ignore_changes = [source_code_hash, s3_key, s3_bucket, environment]
  }
}

resource "aws_lambda_function_url" "this" {
  # Only functions that declare public_url get a URL (true = public, false = AWS_IAM).
  for_each = { for k, f in var.functions : k => f if f.public_url != null }

  function_name      = aws_lambda_function.this[each.key].function_name
  authorization_type = each.value.public_url ? "NONE" : "AWS_IAM"
  invoke_mode        = each.value.invoke_mode
}
