# ─── Service accounts ───
# Adopted as-is. Their static access keys are intentionally NOT managed here:
# a static key's secret is only shown at creation and cannot be read back, so
# importing it would force a rotation that breaks whatever uses the key.

locals {
  service_accounts = {
    "recepter-monitoring"  = { description = null, labels = null }
    "gistrec"              = { description = null, labels = null }
    "recepter-s3"          = { description = null, labels = null }
    "aleksandravoo"        = { description = null, labels = { project = "aleksandravoo" } }
    "clear-transcript-bot" = { description = "Storage + SpeechKit", labels = null }
    "dnd-crime"            = { description = null, labels = null }
    "wordstat"             = { description = null, labels = null }
    "mysql-backup"         = { description = "MySQL off-site backup uploader (write-only)", labels = { role = "mysql-backup" } }
    "recepter"             = { description = null, labels = null }
    "realm-status"         = { description = "realm-status fn: Lockbox read + self-invoke", labels = { project = "realm-status" } }
  }
}

resource "yandex_iam_service_account" "this" {
  for_each = local.service_accounts

  name        = each.key
  description = each.value.description
  labels      = each.value.labels
}
