# Geo-маршрутизация glucose.gistrec.cloud: из РФ — на russia-03, отовсюду
# ещё — на finland-01. Обе копии отдают одно и то же (см. apps.yml: glucose /
# glucose-mirror); в РФ снимок приезжает по wg-тоннелю кроном.
#
# Делегирован ОДИН поддомен, а не вся зона: NS-записи для glucose.gistrec.cloud
# стоят в Cloudflare (terraform/dns), остальное gistrec.cloud остаётся там же.
# Сертификат это не трогает — *.gistrec.cloud покрывает имя, а DNS-01 для
# wildcard проходит в родительской зоне.

resource "gcore_dns_zone" "glucose" {
  name = "glucose.gistrec.cloud"
}

resource "gcore_dns_zone_record" "glucose_apex" {
  zone   = gcore_dns_zone.glucose.name
  domain = gcore_dns_zone.glucose.name
  type   = "A"
  # TTL — пол времени переключения: правило geo и будущий healthcheck доходят
  # до клиента не быстрее, чем истечёт кэш резолвера. 120 — не выбор, а
  # минимум free-плана (меньше API отдаёт 400).
  ttl = 120

  # Порядок фильтров — конвейер: geodns оставляет записи, подходящие клиенту,
  # default подставляет запасную, если не подошла ни одна, first_n режет до
  # одной. Без default клиент из страны вне правил не получил бы ничего.
  filter {
    type = "geodns"
  }

  filter {
    type = "default"
  }

  filter {
    type   = "first_n"
    limit  = 1
    strict = false
  }

  resource_record {
    content = var.host_ips["russia-03"]
    enabled = true

    meta {
      countries = var.rf_countries
    }
  }

  resource_record {
    content = var.host_ips["finland-01"]
    enabled = true

    # default = запасной ответ для всех, кого не поймало правило выше.
    meta {
      default = true
    }
  }
}
