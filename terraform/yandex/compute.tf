# ─── Compute Cloud instances ───
# metadata (ssh-keys, user-data, and console's private_ui_modified_at, which
# changes every time the VM is opened in the console) is under ignore_changes —
# it is huge and externally mutated, so it is adopted as-is rather than managed.

locals {
  instances = {
    # hostname / disk_name keep their pre-rename values: changing either forces
    # VM recreation (hostname) or touches immutable initialize_params (disk).
    "russia-01" = {
      memory    = 4
      image_id  = "fd8n7dushkonnbvt3lpc"
      disk_size = 65
      disk_name = "projects"
      hostname  = "projects"
    }
    "russia-02" = {
      memory    = 2
      image_id  = "fd8chrq89mmk8tqm85r8"
      disk_size = 20
      disk_name = "disk-ubuntu-24-04-lts-1734197525817"
      hostname  = "vk-ads-tool"
    }
  }
}

resource "yandex_compute_instance" "this" {
  for_each = local.instances

  name                      = each.key
  hostname                  = each.value.hostname
  platform_id               = "standard-v3"
  zone                      = var.zone
  service_account_id        = yandex_iam_service_account.this["gistrec"].id
  network_acceleration_type = "standard"

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
    gce_http_endpoint    = 1
    gce_http_token       = 1
  }

  scheduling_policy {
    preemptible = false
  }

  lifecycle {
    ignore_changes = [metadata]
  }
}
