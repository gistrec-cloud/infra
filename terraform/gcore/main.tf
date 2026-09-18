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

  # SOA-поля проставляет Gcore; без этого план вечно хотел бы их обнулить.
  lifecycle {
    ignore_changes = [contact, expiry, nx_ttl, primary_server, refresh, retry, serial]
  }
}

resource "gcore_dns_zone_record" "glucose_apex" {
  zone   = gcore_dns_zone.glucose.name
  domain = gcore_dns_zone.glucose.name
  type   = "A"
  # Пол времени переключения, и он же минимум free-плана: ниже API отдаёт 400.
  ttl = 120

  # Конвейер: geodns отбирает подходящие клиенту, default спасает тех, кому не
  # подошло ничего, first_n режет до одной.
  #
  # is_healthy нет: аккаунту healthcheck'и недоступны — API отвечает 200 и молча
  # выбрасывает и фильтр, и meta.failover (проверено прямым PUT). Когда появятся,
  # ставить его ПЕРВЫМ: после geodns он оставил бы РФ-клиента с пустым ответом.
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
