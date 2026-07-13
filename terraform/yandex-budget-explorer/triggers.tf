# ─── Timer trigger: fire sync-transactions every 6 hours ───
resource "yandex_function_trigger" "sync_transactions_timer" {
  name = "sync-transactions-each-6-hours"

  function {
    id                 = yandex_function.this["sync-transactions"].id
    service_account_id = yandex_iam_service_account.budget_explorer.id
    tag                = "$latest"
    retry_attempts     = "3"
    retry_interval     = "60"
  }

  timer {
    cron_expression = "0 */6 ? * *"
  }
}
