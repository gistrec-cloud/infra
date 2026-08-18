# russia-03 — Timeweb Cloud, SPb (ru-1). Replaces russia-01 (Yandex Cloud) as
# the RF host; later becomes the permanent MySQL primary (replica+promote off
# finland-01). Preset 2455 = Cloud-80: 4×3.3 GHz / 8 GB / 80 GB NVMe, 1800 ₽/mo.
# Panel backups stay off on purpose: hosts are cattle, data lives in MySQL with
# off-site S3 dumps.
resource "twc_ssh_key" "russia_03" {
  name = "russia-03"
  # Public half of the 1Password SSH key "russia-03" (vault "Gistrec Cloud").
  body = "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIM96HKxpBSpuOsGI+Km+ShPOsEuGs3Gc2g7+gjRiBNpD"
}

resource "twc_server" "russia_03" {
  name         = "russia-03"
  hostname     = "russia-03"
  os_id        = 99   # ubuntu 24.04
  preset_id    = 2455 # ru-1 Cloud-80: 4×3.3 GHz / 8 GB / 80 GB NVMe
  ssh_keys_ids = [twc_ssh_key.russia_03.id]

  lifecycle {
    prevent_destroy = true
  }
}

# Public IPv4 (+200 ₽/mo). API-created servers come up IPv6-only — the v4 is a
# floating IP bound to the server; zone must match the server's.
resource "twc_floating_ip" "russia_03" {
  availability_zone = "spb-3"
  comment           = "russia-03 public IPv4"
  ptr               = "russia-03.vps.gistrec.cloud"

  resource {
    type = "server"
    id   = twc_server.russia_03.id
  }
}
