# ─── Per-function execution roles (adopted) ───
# Keyed by function name; main.tf resolves a function's role automatically:
# explicit role_arn > per-function role from this file > shared lambda_exec.

data "aws_caller_identity" "current" {}

# Trust for roles that EventBridge Scheduler also assumes (timer-invoked functions).
data "aws_iam_policy_document" "assume_with_scheduler" {
  source_policy_documents = [data.aws_iam_policy_document.assume.json]

  statement {
    actions = ["sts:AssumeRole"]
    principals {
      type        = "Service"
      identifiers = ["scheduler.amazonaws.com"]
    }
    condition {
      test     = "StringEquals"
      variable = "aws:SourceAccount"
      values   = [data.aws_caller_identity.current.account_id]
    }
  }
}

locals {
  function_roles = {
    "openai-relay" = {
      name            = "openai-relay-role"
      scheduler_trust = false
    }
    "anthropic-relay" = {
      name            = "anthropic-relay-role"
      scheduler_trust = false
    }
    "yandex-rating-counter" = {
      name            = "lambda-yandex-rating-counter"
      scheduler_trust = true # invoked by the EventBridge Scheduler timer
    }
  }

  # role attachments: policy_key points at aws_iam_policy.this, policy_arn is used as-is
  role_attachments = {
    "openai-relay|basic-exec"           = { fn = "openai-relay", policy_arn = "arn:aws:iam::aws:policy/service-role/AWSLambdaBasicExecutionRole", policy_key = null }
    "anthropic-relay|basic-exec"        = { fn = "anthropic-relay", policy_arn = "arn:aws:iam::aws:policy/service-role/AWSLambdaBasicExecutionRole", policy_key = null }
    "yandex-rating-counter|cloudwatch"  = { fn = "yandex-rating-counter", policy_arn = null, policy_key = "cloudwatch-yandex-rating-counter" }
    "yandex-rating-counter|self-invoke" = { fn = "yandex-rating-counter", policy_arn = null, policy_key = "lambda-yandex-rating-counter" }
  }
}

resource "aws_iam_role" "per_function" {
  for_each = local.function_roles

  name               = each.value.name
  assume_role_policy = each.value.scheduler_trust ? data.aws_iam_policy_document.assume_with_scheduler.json : data.aws_iam_policy_document.assume.json
}

resource "aws_iam_role_policy_attachment" "per_function" {
  for_each = local.role_attachments

  role       = aws_iam_role.per_function[each.value.fn].name
  policy_arn = each.value.policy_key != null ? aws_iam_policy.this[each.value.policy_key].arn : each.value.policy_arn
}

# ─── Customer-managed policies used by the roles above ───

data "aws_iam_policy_document" "cloudwatch_yandex_rating_counter" {
  statement {
    actions   = ["logs:CreateLogGroup"]
    resources = ["arn:aws:logs:${var.aws_region}:${data.aws_caller_identity.current.account_id}:*"]
  }
  statement {
    actions   = ["logs:CreateLogStream", "logs:PutLogEvents"]
    resources = ["arn:aws:logs:${var.aws_region}:${data.aws_caller_identity.current.account_id}:log-group:/aws/lambda/yandex-rating-counter:*"]
  }
  statement {
    actions   = ["cloudwatch:PutMetricData"]
    resources = ["*"]
  }
}

data "aws_iam_policy_document" "lambda_yandex_rating_counter" {
  statement {
    # The only consumer of this role is the EventBridge Scheduler target
    # (schedules.tf), which needs invoke and nothing more. lambda:* let a
    # compromised function rewrite/delete its own definition — scope it down.
    sid       = "SelfInvoke"
    actions   = ["lambda:InvokeFunction"]
    resources = ["arn:aws:lambda:${var.aws_region}:${data.aws_caller_identity.current.account_id}:function:yandex-rating-counter"]
  }
}

resource "aws_iam_policy" "this" {
  for_each = {
    "cloudwatch-yandex-rating-counter" = data.aws_iam_policy_document.cloudwatch_yandex_rating_counter.json
    "lambda-yandex-rating-counter"     = data.aws_iam_policy_document.lambda_yandex_rating_counter.json
  }

  name   = each.key
  policy = each.value
}
