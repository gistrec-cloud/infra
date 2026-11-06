# redis

Локальный **Redis-кэш** на хосте приложения. Роль есть, но ни на одном хосте
не включена: потребителей пока нет.

**Redis — только кэш. Все данные живут в MySQL** (primary + реплика + бэкапы в S3).
Реплики и персистентности у Redis нет: при рестарте или уничтожении хоста он
стартует пустым, приложение наполняет кэш заново из MySQL. Если данные жалко
потерять, им место в таблице MySQL, а не в Redis.

- `redis-server` из apt, bind только на loopback (assert не пустит другой адрес).
- Без персистентности (`save ""`, `appendonly no`).
- `maxmemory` + `allkeys-lru`; `FLUSHALL`/`CONFIG`/`DEBUG` отключены.
- Мониторинг: стоковый go.d-коллектор redis netdata сам находит `127.0.0.1:6379`.

Общий Redis по wg не ставить: потери RF↔EU ударят по каждому запросу.

## Включить

1. host_vars: `redis_managed: true` (+ при необходимости `redis_maxmemory`).
2. `make check`, затем `make deploy` (или `--tags redis -l <host>`).

| Переменная | По умолчанию |
|---|---|
| `redis_bind` | `127.0.0.1` |
| `redis_port` | `6379` |
| `redis_maxmemory` | `256mb` |
| `redis_maxmemory_policy` | `allkeys-lru` |
| `redis_password` | `""` (без пароля) |
