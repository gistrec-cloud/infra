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

# Grant payloadViewer per-secret rather than folder-wide, and only on the 5 secrets
# the functions actually mount (local.function_secrets in functions.tf) — nothing
# mounts webhook-secret, so the SA gets no grant on it. The live folder-wide roles
# the SA runs on today stay unmanaged; dropping them is a manual follow-up.
resource "yandex_lockbox_secret_iam_member" "functions" {
  for_each = toset([for s in local.function_secrets : s.lockbox])

  secret_id = yandex_lockbox_secret.this[each.value].id
  role      = "lockbox.payloadViewer"
  member    = "serviceAccount:${yandex_iam_service_account.budget_explorer.id}"
}
