data "aws_iam_policy_document" "assume" {
  statement {
    actions = ["sts:AssumeRole"]
    principals {
      type        = "Service"
      identifiers = ["lambda.amazonaws.com"]
    }
  }
}

resource "aws_iam_role" "lambda_exec" {
  name               = "${var.name_prefix}-lambda-exec"
  assume_role_policy = data.aws_iam_policy_document.assume.json
}

resource "aws_iam_role_policy_attachment" "basic" {
  role       = aws_iam_role.lambda_exec.name
  policy_arn = "arn:aws:iam::aws:policy/service-role/AWSLambdaBasicExecutionRole"
}

resource "aws_lambda_function" "this" {
  for_each = var.functions

  function_name = each.key
  role          = aws_iam_role.lambda_exec.arn
  runtime       = each.value.runtime
  handler       = each.value.handler
  s3_bucket     = each.value.s3_bucket
  s3_key        = each.value.s3_key
  memory_size   = each.value.memory_size
  timeout       = each.value.timeout

  dynamic "environment" {
    for_each = length(each.value.env) > 0 ? [1] : []
    content {
      variables = each.value.env
    }
  }

  # Application code is shipped by a separate pipeline; Terraform owns config only.
  lifecycle {
    ignore_changes = [source_code_hash, s3_key]
  }
}

resource "aws_lambda_function_url" "this" {
  for_each = var.functions

  function_name      = aws_lambda_function.this[each.key].function_name
  authorization_type = each.value.public_url ? "NONE" : "AWS_IAM"
}
