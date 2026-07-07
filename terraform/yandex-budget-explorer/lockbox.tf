# ─── Lockbox secrets (containers only; versions/payloads left untouched) ───
locals {
  lockbox_secrets = [
    "budget-explorer-mysql-password",
    "budget-explorer-claude-api-key",
    "budget-explorer-raifaisen-hashed-password",
    "budget-explorer-exchangerate-api-key",
    "budget-explorer-webhook-secret",
    "budget-explorer-telegram-token",
  ]
}

resource "yandex_lockbox_secret" "this" {
  for_each = toset(local.lockbox_secrets)

  name                = each.value
  deletion_protection = true
  labels              = { project = "budget-explorer" }
}
