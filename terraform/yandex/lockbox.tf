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

# The realm-status function's SA reads every secret in this file (all of them are
# its own realmctl-* secrets). Grant payloadViewer per-secret rather than granting
# lockbox.payloadViewer folder-wide, so the SA can decrypt only these payloads.
resource "yandex_lockbox_secret_iam_member" "realm_status" {
  for_each = yandex_lockbox_secret.this

  secret_id = each.value.id
  role      = "lockbox.payloadViewer"
  member    = "serviceAccount:${yandex_iam_service_account.this["realm-status"].id}"
}
