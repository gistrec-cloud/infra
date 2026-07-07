# ─── Cloud Functions ───
# Terraform owns the deploy: the zip is built from the app source (var-provided
# path, kept out of git) and a new version is published on apply. This replaces
# the app repo's deploy.sh `yc serverless function version create` step.

data "archive_file" "realm_status" {
  type        = "zip"
  source_dir  = var.realm_status_source_dir
  output_path = "${path.module}/.dist/realm-status.zip"

  excludes = [
    ".git",
    ".gitignore",
    ".venv",
    "venv",
    ".dist",
    ".ruff_cache",
    "__pycache__",
    "deploy.sh",
    "README.md",
    "pyvenv.cfg",
    "mypy.ini",
    "pyrightconfig.json",
  ]
}

resource "yandex_function" "realm_status" {
  name               = "realm-status"
  runtime            = "python314"
  entrypoint         = "main.handler"
  memory             = 128
  execution_timeout  = "30"
  service_account_id = yandex_iam_service_account.this["gistrec"].id

  user_hash = data.archive_file.realm_status.output_base64sha256
  content {
    zip_filename = data.archive_file.realm_status.output_path
  }

  environment = {
    MYSQL_HOST           = "projects.mysql.gistrec.cloud"
    MYSQL_PORT           = "3306"
    MYSQL_USER           = "realmctl"
    MYSQL_DB             = "realmctl"
    TELEGRAM_CHAT_ID     = "-1003410760885"
    STARDEW_API_BASE_URL = "http://sv.makstashkevich.com:8080"
  }

  secrets {
    id                   = yandex_lockbox_secret.this["realmctl-telegram-token"].id
    version_id           = "e6q2he0ggsgld4ukqcie"
    key                  = "telegram-token"
    environment_variable = "TELEGRAM_BOT_TOKEN"
  }
  secrets {
    id                   = yandex_lockbox_secret.this["realmctl-mysql-password"].id
    version_id           = "e6qtemr6p5f14k1u6l0q"
    key                  = "mysql-password"
    environment_variable = "MYSQL_PASSWORD"
  }
  secrets {
    id                   = yandex_lockbox_secret.this["realmctl-stardew-api-token"].id
    version_id           = "e6q23l5014cn0vsgjvp6"
    key                  = "stardew-api-token"
    environment_variable = "STARDEW_API_TOKEN"
  }
}

# ─── upload-photo-to-recepter-s3 — still DEFERRED ───
# Its source repo isn't available locally (no dir / deploy.sh / zip found under
# ~/Projects). Add it the same way once the source is on disk:
#   data "archive_file" "upload_photo" { source_dir = var.upload_photo_source_dir ... }
#   resource "yandex_function" "upload_photo" {
#     name = "upload-photo-to-recepter-s3"  runtime = "python314"  entrypoint = "index.handler"
#     service_account_id = yandex_iam_service_account.this["recepter-s3"].id
#     content { zip_filename = data.archive_file.upload_photo.output_path }
#     connectivity { network_id = var.network_id }
#     mounts { name = "recepter"  mode = "rw"  object_storage { bucket = "recepter" } }
#   }
#   import { to = yandex_function.upload_photo  id = "d4ellono884ht963q4uq" }
