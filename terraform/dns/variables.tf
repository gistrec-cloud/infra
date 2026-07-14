variable "cloudflare_api_token" {
  description = "Cloudflare API token with DNS:Edit permission for all managed zones."
  type        = string
  sensitive   = true
}

variable "cloudflare_zone_ids" {
  description = "Managed domains: map of domain name => Cloudflare Zone ID. Real values live in terraform.tfvars (gitignored)."
  type        = map(string)
  default     = {}
}

variable "dns_records" {
  description = <<-EOT
    DNS records to manage. Real values live in terraform.tfvars (gitignored).
    Each record's `zone` must be a key of `cloudflare_zone_ids`.
    Supports A / AAAA / CNAME / TXT / NS and priority-bearing MX (via `priority`).
  EOT
  type = list(object({
    zone     = string
    name     = string
    type     = string
    content  = string
    ttl      = optional(number, 1) # 1 = automatic (required when proxied = true)
    proxied  = optional(bool, false)
    priority = optional(number) # required for MX; omit for other types
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
