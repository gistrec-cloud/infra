# ─── Folder-level IAM bindings ───
# Additive `..._iam_member` (one role↔member pair each) — NOT the authoritative
# `..._iam_binding`/`..._iam_policy`, which would delete any binding not listed here.
# Service-account grants reference the adopted SAs; personal userAccount grants take
# their ids from a gitignored variable.
#
# glucose-bot is the exception: its grant is scoped to its own bucket rather than the
# folder. A folder-level storage.editor would let the bot's static key reach every
# bucket in the folder — gistrec-cloud with a year of MySQL backups included — and it
# only ever touches one. editor, not uploader: it deletes the photos of a cancelled
# draft, and uploader can only write, so the delete would fail silently.
# Note this one IS the authoritative `_binding`: it owns the whole member list for
# that role on that bucket, which is safe only because the bucket is ours alone.

locals {
  # role → service-account (logical key in service_accounts.tf)
  folder_iam_sa = {
    "search-api.executor|wordstat"               = { role = "search-api.executor", sa = "wordstat" }
    "search-api.webSearch.user|wordstat"         = { role = "search-api.webSearch.user", sa = "wordstat" }
    "storage.editor|clear-transcript-bot"        = { role = "storage.editor", sa = "clear-transcript-bot" }
    "ai.speechkit-stt.user|clear-transcript-bot" = { role = "ai.speechkit-stt.user", sa = "clear-transcript-bot" }
    "storage.admin|recepter-s3"                  = { role = "storage.admin", sa = "recepter-s3" }
    "storage.editor|aleksandravoo"               = { role = "storage.editor", sa = "aleksandravoo" }
    "monitoring.admin|recepter-monitoring"       = { role = "monitoring.admin", sa = "recepter-monitoring" }
    "monitoring.admin|recepter"                  = { role = "monitoring.admin", sa = "recepter" }
    "admin|recepter"                             = { role = "admin", sa = "recepter" }
    "storage.uploader|mysql-backup"              = { role = "storage.uploader", sa = "mysql-backup" }
  }

  # monitoring.viewer for personal user accounts (ids in gitignored terraform.tfvars)
  folder_iam_users = {
    for id in var.monitoring_viewer_user_ids :
    "monitoring.viewer|${id}" => { role = "monitoring.viewer", user_id = id }
  }
}

resource "yandex_resourcemanager_folder_iam_member" "sa" {
  for_each = local.folder_iam_sa

  folder_id = var.folder_id
  role      = each.value.role
  member    = "serviceAccount:${yandex_iam_service_account.this[each.value.sa].id}"
}

resource "yandex_resourcemanager_folder_iam_member" "user" {
  for_each = local.folder_iam_users

  folder_id = var.folder_id
  role      = each.value.role
  member    = "userAccount:${each.value.user_id}"
}

# ─── Bucket-scoped IAM ───
# Ровно один бакет и ровно один аккаунт: ключ бота дотягивается только до
# фотографий еды и никуда больше.

resource "yandex_storage_bucket_iam_binding" "glucose_bot" {
  bucket  = yandex_storage_bucket.this["glucose-bot"].bucket
  role    = "storage.editor"
  members = ["serviceAccount:${yandex_iam_service_account.this["glucose-bot"].id}"]
}
