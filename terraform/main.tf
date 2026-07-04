provider "cloudflare" {
  api_token = var.cloudflare_api_token
}

# DNS records are *data*: the real set lives in terraform.tfvars (gitignored).
# This manages them as code — see terraform.tfvars.example for the shape.
resource "cloudflare_dns_record" "this" {
  for_each = {
    for r in var.dns_records :
    "${r.type}:${r.name}:${r.content}:${r.priority == null ? "" : tostring(r.priority)}" => r
  }

  zone_id  = var.cloudflare_zone_id
  name     = each.value.name
  type     = each.value.type
  content  = each.value.content
  ttl      = each.value.ttl
  proxied  = each.value.proxied
  priority = each.value.priority
}
