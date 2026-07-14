# ─── EventBridge Scheduler: hourly yandex-rating-counter run ───
# The scheduler assumes the function's own role (its trust policy allows
# scheduler.amazonaws.com — see roles.tf) to invoke the lambda.
resource "aws_scheduler_schedule" "yandex_rating_counter" {
  name  = "yandex-rating-counter"
  state = "ENABLED"

  schedule_expression          = "cron(0 * * * ? *)"
  schedule_expression_timezone = "Europe/Belgrade"

  flexible_time_window {
    mode = "OFF"
  }

  target {
    arn      = aws_lambda_function.this["yandex-rating-counter"].arn
    role_arn = aws_iam_role.per_function["yandex-rating-counter"].arn

    retry_policy {
      maximum_event_age_in_seconds = 86400
      maximum_retry_attempts       = 0
    }
  }
}
