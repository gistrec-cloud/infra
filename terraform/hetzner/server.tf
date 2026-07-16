# Existing production VPS, adopted from Hetzner Cloud server ID 151586283.
resource "hcloud_server" "finland_01" {
  name        = "finland-01"
  server_type = "cx33"
  image       = "ubuntu-24.04"
  location    = "hel1"

  backups            = true
  firewall_ids       = []
  labels             = {}
  placement_group_id = 0
  # The hcloud API only accepts these two flipped together. Provider-side
  # guard against console/API deletion; prevent_destroy below only stops TF.
  delete_protection  = true
  rebuild_protection = true

  lifecycle {
    # The SSH key and cloud-init payload were used only to bootstrap the server.
    # Changing them after creation can propose replacement despite Ansible now
    # owning the in-guest SSH configuration.
    ignore_changes  = [ssh_keys, user_data]
    prevent_destroy = true
  }
}
