variable "gcore_permanent_api_token" {
  description = "Gcore permanent API token. From the environment: TF_VAR_gcore_permanent_api_token (.envrc → 1Password)."
  type        = string
  sensitive   = true
}

variable "host_ips" {
  description = <<-EOT
    Fleet hosts: inventory hostname => public IPv4. Duplicated from terraform/dns
    on purpose — the two modules have separate states and no remote backend to
    share outputs through. Keep both in sync when a host moves.
  EOT
  type        = map(string)
}

variable "rf_countries" {
  description = <<-EOT
    Countries routed to the RF origin. Only RU by default: the point is ТСПУ, not
    geography — a Kazakh or Belarusian client reaches Finland fine.
  EOT
  type        = list(string)
  default     = ["ru"]
}
