provider "cloudflare" {
  api_token = var.cloudflare_api_token
}

# DNS records are *data*: the real set lives in terraform.tfvars (gitignored).
# This manages them as code — see terraform.tfvars.example for the shape.
#
# `host` indirection resolves here, BEFORE the for_each keys are built: a key
# embeds the record's content, so switching a record from a literal IP to the
# equivalent `host` keeps its key — a pure refactor plans as no changes.
locals {
  dns_records = [
    for r in var.dns_records :
    merge(r, { content = r.host == null ? r.content : var.host_ips[r.host] })
  ]
}

resource "cloudflare_dns_record" "this" {
  for_each = {
    for r in local.dns_records :
    "${r.zone}:${r.type}:${r.name}:${r.content}:${r.priority == null ? "" : tostring(r.priority)}" => r
  }

  zone_id  = var.cloudflare_zone_ids[each.value.zone]
  name     = each.value.name
  type     = each.value.type
  content  = each.value.content
  ttl      = each.value.ttl
  proxied  = each.value.proxied
  priority = each.value.priority
}
