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
  # Из этого следует про meta.healthcheck: схема провайдера его не знает (в
  # resource_record.meta есть failover типа map(string), и обратно он читается
  # пустым), поэтому у терраформа их нет ни в конфиге, ни в state. Провайдер шлёт
  # запись целиком, так что первая же правка этого ресурса снесёт живые проверки,
  # а plan до того будет показывать «no changes». Пока они инертны, потеря
  # безвредна; когда фильтр заработает — заводить проверки здесь нечем, придётся
  # либо ждать схему провайдера, либо вынести их в отдельный скрипт.
  # И тогда же ставить is_healthy ПЕРВЫМ: после geodns РФ-клиенту остаётся только
  # запись russia-03, и выброс её на последнем шаге дал бы пустой ответ.
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
