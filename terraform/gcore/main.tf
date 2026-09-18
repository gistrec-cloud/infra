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

  # SOA-поля проставляет сам Gcore при создании зоны, в конфиге их нет — и
  # без этого каждый план хотел бы обнулить их заново, показывая изменение,
  # которое ничего не меняет. serial к тому же растёт при каждой правке.
  lifecycle {
    ignore_changes = [contact, expiry, nx_ttl, primary_server, refresh, retry, serial]
  }
}

resource "gcore_dns_zone_record" "glucose_apex" {
  zone   = gcore_dns_zone.glucose.name
  domain = gcore_dns_zone.glucose.name
  type   = "A"
  # TTL — пол времени переключения: изменение правил доходит до клиента не
  # быстрее, чем истечёт кэш резолвера. 120 — не выбор, а минимум free-плана
  # (меньше API отдаёт 400).
  ttl = 120

  # Порядок фильтров — конвейер: geodns оставляет записи, подходящие клиенту,
  # default подставляет запасную, если не подошла ни одна, first_n режет до
  # одной. Без default клиент из страны вне правил не получил бы ничего.
  #
  # Фильтра is_healthy тут НЕТ, и это не забывчивость: аккаунту недоступны
  # healthcheck'и. API отвечает 200 и молча выбрасывает и сам фильтр, и
  # meta.failover — проверено прямым PUT 2026-09-18, в ответе остаются те же
  # три фильтра. Оставлять их в конфиге нельзя: каждый план показывал бы одно
  # и то же изменение, которое никогда не применяется.
  #
  # Когда healthcheck'и появятся, is_healthy должен идти ПЕРВЫМ. Наоборот не
  # работает: geodns оставил бы РФ-клиенту только russia-03, is_healthy выбросил
  # бы его как мёртвый, а до default дело бы не дошло — запись finland к тому
  # моменту уже отфильтрована, и ответ был бы пустым.
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
