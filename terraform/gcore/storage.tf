# ─── Object Storage ───
# Уход из Yandex Object Storage (2026-10-11, после инцидента YC). Один storage =
# один S3-аккаунт с парой ключей, бакеты внутри; имена повторяют Яндекс, чтобы
# cutover был сменой endpoint'а. Бэкапы — в отдельном storage: ключ приложений
# не должен дотягиваться до копий MySQL (тот же принцип, что в terraform/yandex/iam.tf).
# Ключи приезжают в state (generated_*_key); state уже бэкапится в 1Password.
# Копирование и cutover — docs/runbooks/s3-mirror.md.

locals {
  # бакет → storage
  s3_buckets = {
    "aleksandravoo"        = "apps"
    "askads"               = "apps" # не из terraform/yandex (создан руками 2026-09-19), но публичный и живой
    "clear-transcript-bot" = "apps" # только бакет под быстрое переключение, данные не копируем
    "dnd-crime"            = "apps"
    "gistrec-share"        = "apps"
    "glucose-bot"          = "apps"
    "recepter"             = "apps"
    "gistrec-cloud"        = "backups"
  }
}

# name/location/storage_id у провайдера ForceNew: replacement = DeleteStorage/
# DeleteBucket в API вместе с данными. Переезд — только копированием + state mv.
resource "gcore_storage_s3" "main" {
  name = "gistrec"
  # Люксембург: в РФ локаций нет, Алматы (s-kal2) дальше от finland-01.
  location = "s-ed1"

  lifecycle {
    prevent_destroy = true
  }
}

resource "gcore_storage_s3" "backups" {
  name     = "gistrec-backups"
  location = "s-ed1"

  lifecycle {
    prevent_destroy = true
  }
}

resource "gcore_storage_s3_bucket" "this" {
  for_each = local.s3_buckets

  name       = each.key
  storage_id = each.value == "backups" ? gcore_storage_s3.backups.storage_id : gcore_storage_s3.main.storage_id

  lifecycle {
    prevent_destroy = true
  }
}

output "s3_endpoint" {
  value = gcore_storage_s3.main.generated_s3_endpoint
}

output "s3_access_key" {
  value     = gcore_storage_s3.main.generated_access_key
  sensitive = true
}

output "s3_secret_key" {
  value     = gcore_storage_s3.main.generated_secret_key
  sensitive = true
}

output "s3_backups_access_key" {
  value     = gcore_storage_s3.backups.generated_access_key
  sensitive = true
}

output "s3_backups_secret_key" {
  value     = gcore_storage_s3.backups.generated_secret_key
  sensitive = true
}
