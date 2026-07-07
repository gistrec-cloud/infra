# ─── Lockbox secrets (containers only) ───
# Only the secret *containers* are adopted, not their versions: a version's
# payload is the actual secret and is not committed to config. Existing versions
# are left untouched.

locals {
  lockbox_secrets = {
    "realmctl-mysql-password"    = { deletion_protection = true, labels = { project = "realm-status" } }
    "realmctl-stardew-api-token" = { deletion_protection = false, labels = {} }
    "realmctl-telegram-token"    = { deletion_protection = true, labels = {} }
  }
}

resource "yandex_lockbox_secret" "this" {
  for_each = local.lockbox_secrets

  name                = each.key
  deletion_protection = each.value.deletion_protection
  labels              = each.value.labels
}
