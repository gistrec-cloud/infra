# ─── Cloud Functions ───
# Both functions are built from the same source repo (different entrypoints) and
# deployed by Terraform. This replaces the app repo's deploy.sh `yc function
# version create` step. A function import is never a 0-change no-op (the deployed
# user_hash isn't readable), so the first apply republishes the current code.

locals {
  functions = {
    "sync-transactions" = { entrypoint = "main_sync.handler", execution_timeout = "60" }
    "telegram-bot"      = { entrypoint = "main_telegram.handler", execution_timeout = "300" }
  }

  function_env = {
    LOGIN      = "gistrec"
    MYSQL_DB   = "budget-explorer"
    MYSQL_HOST = "projects.mysql.gistrec.cloud"
    MYSQL_PORT = "3306"
    MYSQL_USER = "budget-explorer"
  }

  # env var → (lockbox secret name, key, pinned version)
  function_secrets = [
    { env = "TELEGRAM_BOT_TOKEN", lockbox = "budget-explorer-telegram-token", key = "telegram-token", version = "e6q34oac73jv5g68bi2a" },
    { env = "MYSQL_PASSWORD", lockbox = "budget-explorer-mysql-password", key = "mysql-password", version = "e6qipfvtqv2dtmh03e7i" },
    { env = "EXCHANGE_RATE_API_KEY", lockbox = "budget-explorer-exchangerate-api-key", key = "exchangerate-api-key", version = "e6q5rfsmuikr9bgi9vde" },
    { env = "HASHED_PASSWORD", lockbox = "budget-explorer-raifaisen-hashed-password", key = "hashed-password", version = "e6q98j9bjnhqrm557v99" },
    { env = "ANTHROPIC_API_KEY", lockbox = "budget-explorer-claude-api-key", key = "claude-api-key", version = "e6qknje7hjftcgpsgnv0" },
  ]
}

data "archive_file" "budget_explorer" {
  type        = "zip"
  source_dir  = var.functions_source_dir
  output_path = "${path.module}/.dist/budget-explorer.zip"

  excludes = [
    ".git",
    ".gitignore",
    ".github",
    ".venv",
    "venv",
    ".dist",
    ".ruff_cache",
    ".pytest_cache",
    "__pycache__",
    "deploy.sh",
    "README.md",
    "pyvenv.cfg",
  ]
}

resource "yandex_function" "this" {
  for_each = local.functions

  name               = each.key
  runtime            = "python312"
  entrypoint         = each.value.entrypoint
  memory             = 256
  execution_timeout  = each.value.execution_timeout
  service_account_id = yandex_iam_service_account.budget_explorer.id

  user_hash = data.archive_file.budget_explorer.output_base64sha256
  content {
    zip_filename = data.archive_file.budget_explorer.output_path
  }

  environment = local.function_env

  dynamic "secrets" {
    for_each = local.function_secrets
    content {
      id                   = yandex_lockbox_secret.this[secrets.value.lockbox].id
      version_id           = secrets.value.version
      key                  = secrets.value.key
      environment_variable = secrets.value.env
    }
  }
}
