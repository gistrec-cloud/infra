# ─── Object Storage buckets ───
# Stable attributes are managed here. The per-bucket lifecycle_rule / logging
# configuration is left under ignore_changes: those are managed over the S3 API
# (needs a static key we deliberately don't mint) and are adopted as-is.
# gistrec-cloud backup retention (mysql/+clickhouse/) = 365d, set out-of-band from
# gistrec-cloud-lifecycle.json (uploader key can't prune; bucket lifecycle does).
# glucose-bot holds meal photos — private, and capped rather than unlimited: at
# four 1024px JPEGs per meal it grows ~1 GiB a year, so 10 GiB is a decade of
# headroom and still a ceiling on the bill. Its retention is a lifecycle rule set
# over the S3 API like the others, not a cron in the bot.
#
# folder_id is per-bucket and stays null for the adopted ones. Creating a bucket
# under a UserAccount IAM token needs it spelled out — the folder cannot be
# inferred from that kind of token — but the attribute is ForceNew, and the
# provider fills it from the API on read. Setting it on the adopted buckets would
# therefore compare a config value against whatever the API returned and, on any
# mismatch, destroy and recreate them. Null means "keep what is there".

locals {
  buckets = {
    "aleksandravoo"        = { max_size = 53687091200, anonymous_read = true, folder_id = null, tags = { project = "aleksandravoo" } }
    "clear-transcript-bot" = { max_size = 0, anonymous_read = false, folder_id = null, tags = { project = "clear-transcript-bot" } }
    "dnd-crime"            = { max_size = 53687091200, anonymous_read = true, folder_id = null, tags = {} }
    "gistrec-cloud"        = { max_size = 53687091200, anonymous_read = false, folder_id = null, tags = {} }
    "glucose-bot"          = { max_size = 10737418240, anonymous_read = false, folder_id = var.folder_id, tags = { project = "glucose-bot" } }
    "recepter"             = { max_size = 0, anonymous_read = true, folder_id = null, tags = { project = "recepter" } }
  }
}

resource "yandex_storage_bucket" "this" {
  for_each = local.buckets

  bucket                = each.key
  default_storage_class = "STANDARD"
  max_size              = each.value.max_size
  folder_id             = each.value.folder_id
  tags                  = each.value.tags

  anonymous_access_flags {
    read        = each.value.anonymous_read
    list        = false
    config_read = false
  }

  lifecycle {
    ignore_changes = [lifecycle_rule, logging]
  }
}
