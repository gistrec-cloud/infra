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
    "wordstat"             = { description = null, labels = null }
    "linkgrow"             = { description = null, labels = { project = "linkgrow" } }
    "recepter"             = { description = null, labels = null }
  }
}

resource "yandex_iam_service_account" "this" {
  for_each = local.service_accounts

  name        = each.key
  description = each.value.description
  labels      = each.value.labels
}
