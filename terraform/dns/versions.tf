terraform {
  # 1.9+: dns_records validation references var.host_ips (cross-variable).
  required_version = ">= 1.9"

  required_providers {
    cloudflare = {
      source  = "cloudflare/cloudflare"
      version = "~> 5.0"
    }
  }
}
