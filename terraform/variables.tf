variable "cloudflare_api_token" {
  description = "Cloudflare API token with DNS:Edit permission for the zone."
  type        = string
  sensitive   = true
}

variable "cloudflare_zone_id" {
  description = "Cloudflare Zone ID of the domain to manage."
  type        = string
}

variable "dns_records" {
  description = <<-EOT
    DNS records to manage. Real values live in terraform.tfvars (gitignored).
    Supports A / AAAA / CNAME / TXT / NS and priority-bearing MX (via `priority`).
  EOT
  type = list(object({
    name     = string
    type     = string
    content  = string
    ttl      = optional(number, 1)  # 1 = automatic (required when proxied = true)
    proxied  = optional(bool, false)
    priority = optional(number)     # required for MX; omit for other types
  }))
  default = []

  validation {
    condition = alltrue([
      for r in var.dns_records :
      r.proxied != true || contains(["A", "AAAA", "CNAME"], r.type)
    ])
    error_message = "proxied = true is only valid for A, AAAA and CNAME records."
  }
}
