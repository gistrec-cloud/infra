# ─── Object Storage: service account + static key + bucket ───
resource "yandex_iam_service_account" "storage" {
  name = "${var.bucket_name}-sa"
}

resource "yandex_resourcemanager_folder_iam_member" "storage_editor" {
  folder_id = var.folder_id
  role      = "storage.editor"
  member    = "serviceAccount:${yandex_iam_service_account.storage.id}"
}

resource "yandex_iam_service_account_static_access_key" "storage" {
  service_account_id = yandex_iam_service_account.storage.id
  description        = "Static access key for the object storage bucket"
}

resource "yandex_storage_bucket" "this" {
  bucket     = var.bucket_name
  access_key = yandex_iam_service_account_static_access_key.storage.access_key
  secret_key = yandex_iam_service_account_static_access_key.storage.secret_key
}

# ─── Generated DB password → Lockbox ───
resource "random_password" "db" {
  length           = 24
  special          = true
  override_special = "!#$%*-_=+"
}

resource "yandex_lockbox_secret" "db" {
  name = "${var.mysql_db_name}-password"
}

resource "yandex_lockbox_secret_version" "db" {
  secret_id = yandex_lockbox_secret.db.id

  entries {
    key        = "password"
    text_value = random_password.db.result
  }
}

# ─── Managed MySQL ───
resource "yandex_mdb_mysql_cluster" "this" {
  name        = "${var.mysql_db_name}-cluster"
  environment = "PRODUCTION"
  network_id  = var.network_id
  version     = var.mysql_version

  resources {
    resource_preset_id = var.mysql_resource_preset
    disk_type_id       = "network-ssd"
    disk_size          = var.mysql_disk_size
  }

  host {
    zone      = var.zone
    subnet_id = var.subnet_id
  }
}

resource "yandex_mdb_mysql_database" "this" {
  cluster_id = yandex_mdb_mysql_cluster.this.id
  name       = var.mysql_db_name
}

resource "yandex_mdb_mysql_user" "this" {
  cluster_id = yandex_mdb_mysql_cluster.this.id
  name       = var.mysql_user_name
  password   = random_password.db.result

  permission {
    database_name = yandex_mdb_mysql_database.this.name
    roles         = ["ALL"]
  }
}

# ─── Compute Cloud instance ───
data "yandex_compute_image" "this" {
  family = var.compute_image_family
}

resource "yandex_compute_instance" "this" {
  name        = var.compute_name
  zone        = var.zone
  platform_id = "standard-v3"

  resources {
    cores  = var.compute_cores
    memory = var.compute_memory
  }

  boot_disk {
    initialize_params {
      image_id = data.yandex_compute_image.this.id
    }
  }

  network_interface {
    subnet_id = var.subnet_id
    nat       = true
  }
}

# ─── Cloud Function ───
resource "yandex_function" "this" {
  name       = var.function_name
  runtime    = var.function_runtime
  entrypoint = var.function_entrypoint
  memory     = 128
  user_hash  = "v1"

  content {
    zip_filename = var.function_zip
  }
}
