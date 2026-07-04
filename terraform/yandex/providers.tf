# Auth via env: YC_TOKEN, or YC_SERVICE_ACCOUNT_KEY_FILE=key.json.
provider "yandex" {
  cloud_id  = var.cloud_id
  folder_id = var.folder_id
  zone      = var.zone
}
