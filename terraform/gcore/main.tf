# Geo-маршрутизация: из РФ — на russia-03, отовсюду ещё — на finland-01.
# Список имён в geo_names (terraform.tfvars).
#
# Что отдаёт РФ-адрес, зависит от сервиса: glucose собирает страницу сам из
# локальной реплики, остальные проксируют на finland-01 по wg (apps.yml, *-rf).
# Для развязки это неважно — важно лишь, что клиент приходит на российский IP.
#
# Делегируются ОТДЕЛЬНЫЕ поддомены, а не зона целиком: NS-записи стоят в
# Cloudflare (terraform/dns), остальное gistrec.cloud остаётся там. Сертификат
# это не трогает — *.gistrec.cloud покрывает имена, а DNS-01 для wildcard
# проходит в родительской зоне.

resource "gcore_dns_zone" "this" {
  for_each = toset(var.geo_names)

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
  # подошло ничего, first_n режет до одной.
  #
  # is_healthy нет, и это не недосмотр. Выяснено 2026-09-18 на DNS Pro:
  #   - имя валидное, API сам перечисляет его среди допустимых;
  #   - при записи фильтр молча вырезается — и через провайдера, и прямым PUT,
  #     и даже при сохранении из их собственной панели;
  #   - проверки живут в meta.healthcheck (НЕ failover, как в доках провайдера)
  #     и сохраняются, но без фильтра инертны: с заведомо падающей проверкой
  #     ответ не менялся три минуты.
  # Сами meta.healthcheck проставлены руками через API и терраформом НЕ
  # управляются — правка этого ресурса может их снести.
  # Когда фильтр заработает, ставить его ПЕРВЫМ: после geodns РФ-клиенту
  # осталась бы только запись russia-03, и выброс её дал бы пустой ответ.
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
