output "finland_01" {
  description = "Adopted Hetzner Cloud server identity and public addresses."
  value = {
    id           = hcloud_server.finland_01.id
    server_type  = hcloud_server.finland_01.server_type
    location     = hcloud_server.finland_01.location
    ipv4_address = hcloud_server.finland_01.ipv4_address
    ipv6_network = hcloud_server.finland_01.ipv6_network
  }
}
