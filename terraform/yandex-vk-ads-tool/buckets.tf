# ─── Object Storage bucket ───
resource "yandex_storage_bucket" "vk_ads_tool_landing" {
  bucket                = "vk-ads-tool-landing"
  default_storage_class = "STANDARD"
  max_size              = 1073741824

  anonymous_access_flags {
    read        = false
    list        = false
    config_read = false
  }

  lifecycle {
    ignore_changes = [lifecycle_rule, logging]
  }
}
