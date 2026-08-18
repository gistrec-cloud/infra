output "russia_03" {
  description = "Timeweb Cloud server identity and public address."
  value = {
    id        = twc_server.russia_03.id
    status    = twc_server.russia_03.status
    ipv4      = twc_floating_ip.russia_03.ip
  }
}
