# ─── Compute Cloud instances ───
# metadata (ssh-keys, user-data, and console's private_ui_modified_at, which
# changes every time the VM is opened in the console) is under ignore_changes —
# it is huge and externally mutated, so it is adopted as-is rather than managed.

locals {
  # russia-01 (hostname "projects", the last YC instance) RETIRED 2026-08-19:
  # apps/netdata-parent/prober moved to russia-03 (Timeweb), journal+env
  # evacuated, canary stop passed. Empty map keeps the resource block for
  # future instances.
  instances = {}
}

resource "yandex_compute_instance" "this" {
  for_each = local.instances

  name                      = each.key
  hostname                  = each.value.hostname
  platform_id               = "standard-v3"
  zone                      = var.zone
  network_acceleration_type = "standard"

  # No service account is attached, deliberately. With one attached, the metadata
  # IAM-token endpoint (169.254.169.254/.../service-accounts/default/token) mints a
  # token for that SA to ANY process on the VM — for the SA that used to be here
  # that was an admin-on-the-folder token. Nothing on these boxes needs cloud API
  # access: app secrets live in .env and monitoring is netdata, not Yandex
  # Monitoring. Re-attaching an SA later means flipping gce_http_token back on below
  # AND adding allow_stopping_for_update = true: an SA attach/detach forces an
  # instance stop, which Terraform refuses to do without that flag.

  resources {
    cores         = 2
    memory        = each.value.memory
    core_fraction = 20
  }

  boot_disk {
    auto_delete = true
    mode        = "READ_WRITE"
    initialize_params {
      block_size = 4096
      image_id   = each.value.image_id
      name       = each.value.disk_name
      size       = each.value.disk_size
      type       = "network-ssd"
    }
  }

  network_interface {
    index     = 0
    subnet_id = var.subnet_id
    nat       = true
    ipv4      = true
    ipv6      = false
  }

  metadata_options {
    aws_v1_http_endpoint = 1
    aws_v1_http_token    = 2
    aws_v2_http_endpoint = 2
    aws_v2_http_token    = 2
    gce_http_endpoint    = 1 # metadata endpoint (ssh-keys, user-data) — required
    gce_http_token       = 2 # IAM-token issuance OFF (no SA attached to mint for)
  }

  scheduling_policy {
    preemptible = false
  }

  lifecycle {
    ignore_changes = [metadata]
  }
}
