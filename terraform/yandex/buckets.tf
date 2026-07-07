# ─── Object Storage buckets ───
# Stable attributes are managed here. The per-bucket lifecycle_rule / logging
# configuration is left under ignore_changes: those are managed over the S3 API
# (needs a static key we deliberately don't mint) and are adopted as-is.

locals {
  buckets = {
    "aleksandravoo"        = { max_size = 53687091200, anonymous_read = true, tags = { project = "aleksandravoo" } }
    "clear-transcript-bot" = { max_size = 0, anonymous_read = false, tags = { project = "clear-transcript-bot" } }
    "dnd-crime"            = { max_size = 53687091200, anonymous_read = true, tags = {} }
    "linkgrow"             = { max_size = 0, anonymous_read = true, tags = { project = "linkgrow" } }
    "recepter"             = { max_size = 0, anonymous_read = true, tags = { project = "recepter" } }
  }
}

resource "yandex_storage_bucket" "this" {
  for_each = local.buckets

  bucket                = each.key
  default_storage_class = "STANDARD"
  max_size              = each.value.max_size
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
