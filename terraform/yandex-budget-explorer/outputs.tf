output "service_account_id" {
  value = yandex_iam_service_account.budget_explorer.id
}

output "lockbox_secret_ids" {
  description = "Adopted Lockbox secret containers, name → id."
  value       = { for k, s in yandex_lockbox_secret.this : k => s.id }
}

output "trigger_id" {
  value = yandex_function_trigger.sync_transactions_timer.id
}
