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

variable "host_ips" {
  description = <<-EOT
    Fleet hosts: map of inventory hostname => public IPv4. The single place an
    IP lives — A records reference a host by name (`host`) instead of embedding
    the IP, so re-homing an app or replacing a VPS is a one-word change.
  EOT
  type        = map(string)
  default     = {}
}

variable "dns_records" {
  description = <<-EOT
    DNS records to manage. Real values live in terraform.tfvars (gitignored).
    Each record's `zone` must be a key of `cloudflare_zone_ids`.
    Supports A / AAAA / CNAME / TXT / NS and priority-bearing MX (via `priority`).
    A records may set `host` (a key of `host_ips`) instead of `content`.
  EOT
  type = list(object({
    zone     = string
    name     = string
    type     = string
    content  = optional(string)    # exactly one of content / host
    host     = optional(string)    # A only: content = host_ips[host]
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

  validation {
    condition = alltrue([
      for r in var.dns_records : (r.content == null) != (r.host == null)
    ])
    error_message = "Each record must set exactly one of `content` or `host`."
  }

  validation {
    condition = alltrue([
      for r in var.dns_records : r.host == null || r.type == "A"
    ])
    error_message = "`host` is only valid on A records — host_ips holds IPv4 addresses."
  }

  validation {
    condition = alltrue([
      for r in var.dns_records : r.host == null || contains(keys(var.host_ips), r.host)
    ])
    error_message = "Every record's `host` must be a key of `host_ips`."
  }

  validation {
    condition = length(distinct([
      for r in var.dns_records : "${r.zone}:${r.type}:${r.name}"
      if contains(["A", "AAAA", "CNAME"], r.type)
      ])) == length([
      for r in var.dns_records : r
      if contains(["A", "AAAA", "CNAME"], r.type)
    ])
    error_message = "Duplicate A/AAAA/CNAME (zone, type, name): pointer records are keyed by name only (so moves update in place) — round-robin would need a key extension first."
  }
}
