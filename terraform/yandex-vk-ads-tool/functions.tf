# ─── Cloud Functions — DEFERRED (no local source) ───
#
# Two live functions exist in this folder but their source repos aren't on disk,
# so Terraform can't build a zip to own their deploy:
#   email-sender        (d4e8lds8l5hiup1aqao0)  python312, index.handler, mem 256, timeout 15
#   sentry-to-telegram  (d4eju2umcav443hd646f)  python312, index.handler, mem 128, timeout 3
#                                                 desc "Resend errors from sentry to tg"
# Both have no environment, no secrets and no service account.
#
# To adopt one once its source is available, mirror the budget-explorer module:
#   data "archive_file" "sentry_to_telegram" { source_dir = var.<...>_source_dir ... }
#   resource "yandex_function" "sentry_to_telegram" {
#     name = "sentry-to-telegram"  runtime = "python312"  entrypoint = "index.handler"
#     memory = 128  execution_timeout = "3"
#     user_hash = data.archive_file.sentry_to_telegram.output_base64sha256
#     content { zip_filename = data.archive_file.sentry_to_telegram.output_path }
#   }
#   import { to = yandex_function.sentry_to_telegram  id = "d4eju2umcav443hd646f" }
# First apply republishes the code as a fresh version (import is never a 0-change no-op).
