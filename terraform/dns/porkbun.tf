# Porkbun-hosted zones (dndcrime.com): registered at Porkbun, NS stays at
# Porkbun — no Cloudflare in front. Same data-driven shape as the CF records,
# but the provider's model differs: `domain` is the zone, `name` the subdomain
# part ("" = apex), ttl is a string with a 600 minimum, and there is no proxy.
# NOTE: each zone must have "API ACCESS" toggled on in the Porkbun dashboard
# (Domain Management → details), or every call fails.
provider "porkbun" {
  api_key    = var.porkbun_api_key
  secret_key = var.porkbun_secret_api_key
}

# `host` indirection resolves here, BEFORE the for_each keys are built.
locals {
  porkbun_records = [
    for r in var.porkbun_records :
    merge(r, { content = r.host == null ? r.content : var.host_ips[r.host] })
  ]
}

resource "porkbun_dns_record" "this" {
  # Same keying idea as the CF records: pointer types (A/AAAA/CNAME/ALIAS) by
  # name — a host/content flip is an in-place update; the rest carry content
  # in the key.
  for_each = {
    for r in local.porkbun_records :
    (contains(["A", "AAAA", "CNAME", "ALIAS"], r.type)
      ? "${r.domain}:${r.type}:${r.name}"
      : "${r.domain}:${r.type}:${r.name}:${r.content}:${r.prio == null ? "" : r.prio}"
    ) => r
  }

  domain  = each.value.domain
  name    = each.value.name
  type    = each.value.type
  content = each.value.content
  ttl     = each.value.ttl
  prio    = each.value.prio
}
