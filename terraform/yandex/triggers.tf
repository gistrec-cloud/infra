# ─── Timer trigger: refresh realm status every 5 minutes ───
resource "yandex_function_trigger" "realm_status_timer" {
  name = "realmctl-each-5-mins"

  function {
    id                 = yandex_function.realm_status.id
    service_account_id = yandex_iam_service_account.this["realm-status"].id
    tag                = "$latest"
  }

  timer {
    cron_expression = "*/5 * ? * * *"
  }

  # The invoker role for this SA must exist before the trigger is (re)configured.
  depends_on = [yandex_function_iam_binding.realm_status_invoker]
}
