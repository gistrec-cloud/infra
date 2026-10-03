# Geo-маршрутизация: из РФ — на РФ-сторону, отовсюду ещё — на мировую.
#
# Список имён — geo.json в корне репозитория, общий с terraform/dns (NS-пары) и
# с ansible (сгенерированный прокси-фронт на дальней стороне). Добавить сайт =
# одна запись там; у модулей отдельные state'ы и общего backend'а нет, поэтому
# данные они делят файлом, а не output'ом.
#
# Чем именно отвечает ближний адрес, зависит от сервиса (origin + front в
# geo.json) — для развязки это неважно, важно лишь, что клиент приходит на
# ближний IP.
#
# Делегируются ОТДЕЛЬНЫЕ поддомены, а не зона целиком: NS-записи стоят в
# Cloudflare (terraform/dns), остальное gistrec.cloud остаётся там. Сертификат
# это не трогает — *.gistrec.cloud покрывает имена, а DNS-01 для wildcard
# проходит в родительской зоне. Отсюда и "geo": false у apex-имён: зону по
# поддомену не делегировать, им geo недоступен до переезда зоны целиком.

locals {
  geo = jsondecode(file("${path.module}/../../geo.json"))

  geo_zones = [
    for name, cfg in local.geo.names : name
    if try(cfg.geo, true)
  ]
}

resource "gcore_dns_zone" "this" {
  for_each = toset(local.geo_zones)

  name = each.value

  # SOA-поля проставляет Gcore; без этого план вечно хотел бы их обнулить.
  lifecycle {
    ignore_changes = [contact, expiry, nx_ttl, primary_server, refresh, retry, serial]
  }
}

resource "gcore_dns_zone_record" "apex" {
  for_each = gcore_dns_zone.this

  zone   = each.value.name
  domain = each.value.name
  type   = "A"
  # Пол времени переключения: быстрее истечения кэша резолвера ни geo, ни
  # healthcheck до клиента не дойдут. 30 — минимум плана DNS Pro.
  ttl = 30

  # Конвейер: geodns отбирает подходящих клиенту, default спасает тех, кому не
  # подошло ничего, first_n режет до одной. Развязка по гео — да, отказоустой-
  # чивости НЕТ: упавший russia-03 продолжит получать РФ-трафик.
  #
  # is_healthy нет, и это не недосмотр. Выяснено 2026-09-18 на DNS Pro: имя
  # валидное и API сам перечисляет его среди допустимых, но при записи фильтр
  # молча вырезается — через провайдера, прямым PUT и даже из их собственной
  # панели. Проверки живут в meta.healthcheck (НЕ в failover, как в доках
  # провайдера) и сохраняются, но без фильтра инертны: с заведомо падающей
  # проверкой ответ не менялся три минуты. Вопрос в поддержку не отправлен.
  #
  # Сами проверки на glucose тоже сняты (2026-09-18): схема провайдера их не
  # знает — в resource_record.meta есть только failover типа map(string), и
  # обратно он читается пустым. Терраформ их не видел, но шлёт запись целиком,
  # так что первая же правка ресурса снесла бы их молча, показав до того «no
  # changes». Толку от них не было никакого, а вид failover'а они создавали.
  # Когда фильтр заработает, заводить проверки отсюда будет нечем — либо ждать
  # схему провайдера, либо отдельный скрипт. И тогда же ставить is_healthy
  # ПЕРВЫМ: после geodns РФ-клиенту остаётся одна запись russia-03, и выброс её
  # на последнем шаге дал бы пустой ответ.
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
    content = var.host_ips[local.geo.sides.rf]
    enabled = true

    meta {
      countries = var.rf_countries
    }
  }

  resource_record {
    content = var.host_ips[local.geo.sides.world]
    enabled = true

    # default = запасной ответ для всех, кого не поймало правило выше.
    meta {
      default = true
    }
  }
}
