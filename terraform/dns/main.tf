provider "cloudflare" {
  api_token = var.cloudflare_api_token
}

# DNS records are *data*: the real set lives in terraform.tfvars (gitignored).
# This manages them as code — see terraform.tfvars.example for the shape.
#
# `host` indirection resolves here, BEFORE the for_each keys are built.
locals {
  dns_records = [
    for r in var.dns_records :
    merge(r, { content = r.host == null ? r.content : var.host_ips[r.host] })
  ]
}

resource "cloudflare_dns_record" "this" {
  # A/AAAA/CNAME are keyed by name (kept unique via validation), so a
  # host/content flip — the move operation — is one atomic in-place
  # update; a destroy+create pair races the CF API (81053) and briefly
  # drops the name. TXT/MX/NS may repeat a name, so content/priority
  # stays in their key.
  for_each = {
    for r in local.dns_records :
    (contains(["A", "AAAA", "CNAME"], r.type)
      ? "${r.zone}:${r.type}:${r.name}"
      : "${r.zone}:${r.type}:${r.name}:${r.content}:${r.priority == null ? "" : tostring(r.priority)}"
    ) => r
  }

  zone_id  = var.cloudflare_zone_ids[each.value.zone]
  name     = each.value.name
  type     = each.value.type
  content  = each.value.content
  ttl      = each.value.ttl
  proxied  = each.value.proxied
  priority = each.value.priority
}
