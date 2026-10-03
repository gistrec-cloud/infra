provider "cloudflare" {
  api_token = var.cloudflare_api_token
}

# DNS records are *data*: the real set lives in terraform.tfvars (gitignored).
# This manages them as code — see terraform.tfvars.example for the shape.
#
# `host` indirection resolves here, BEFORE the for_each keys are built.
locals {
  # Делегирование в Gcore — не данные этого модуля: имена перечислены в geo.json
  # (общий файл, см. terraform/gcore), а здесь из них выводится NS-пара в
  # родительской зоне. Иначе одно новое имя стоило бы двух правок в двух файлах,
  # и рассинхрон молча оставлял бы имя без делегирования.
  #
  # Аккаунтные NS Gcore: vanity-серверы только в Enterprise, зона их не отдаёт
  # (gcore_dns_zone не выставляет nameservers), поэтому они здесь константой.
  gcore_nameservers = ["ns1.gcorelabs.net", "ns2.gcdn.services"]

  geo = jsondecode(file("${path.module}/../../geo.json"))

  geo_ns_records = [
    for pair in setproduct(
      [for name, cfg in local.geo.names : name if try(cfg.geo, true)],
      local.gcore_nameservers
      ) : {
      # Родительская зона = имя без первой метки. Делегировать можно только
      # поддомен, так что у любого имени отсюда метка есть.
      zone     = join(".", slice(split(".", pair[0]), 1, length(split(".", pair[0]))))
      name     = pair[0]
      type     = "NS"
      content  = pair[1]
      host     = null
      ttl      = 1
      proxied  = false
      priority = null
    }
  ]

  dns_records = concat(
    [
      for r in var.dns_records :
      merge(r, { content = r.host == null ? r.content : var.host_ips[r.host] })
    ],
    local.geo_ns_records,
  )
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
