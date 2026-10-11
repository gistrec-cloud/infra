# S3-зеркало: Yandex → Gcore

Страховка от отказа Yandex Object Storage (инцидент YC 2026-10-11). Приложения
продолжают писать в Яндекс; finland-01 каждые 6 часов синхронизирует бакеты
приложений в Gcore Люксембург (`s-ed1`). Если РФ-S3 ляжет, данные есть, а
переключение = смена env по списку ниже. Схема и бакеты —
`terraform/gcore/storage.tf`, таймер — роль `s3mirror` (host_vars
`s3mirror_managed`, только finland-01: путь до обеих сторон чистый, с
Timeweb-хостов не гонять — маршрут Timeweb↔Hetzner теряет соединения).

## Что где

| | Gcore storage | ключи | бакеты |
|---|---|---|---|
| приложения | `gistrec` (14688) | `terraform output -raw s3_access_key` / `s3_secret_key` | все, кроме gistrec-cloud |
| бэкапы | `gistrec-backups` (14689) | `s3_backups_access_key` / `s3_backups_secret_key` | gistrec-cloud |

- Endpoint один: `https://s-ed1.cloud.gcore.lu`, region `s-ed1`. Объекты
  публичных бакетов читаются и path-style (`…/recepter/key`), и virtual-host
  (`recepter.s-ed1.cloud.gcore.lu/key`). На отсутствующий ключ Gcore отвечает
  403, не 404.
- Публичность — bucket policy, поставлена `scripts/s3-public-policy.py` на
  aleksandravoo, askads, dnd-crime, gistrec-share, recepter. ACL на объектах не
  нужен, LIST анонимно закрыт, как в Яндексе.
- Ключи у Gcore read-write на весь storage; write-only роли, как
  `storage.uploader` в Яндексе, нет. Поэтому бэкапы в отдельном storage.

Кто куда пишет после 11.10:

| бакет | пишет | читает | зеркало |
|---|---|---|---|
| aleksandravoo, askads, dnd-crime, glucose-bot, recepter | Яндекс (приложения, CI) | Яндекс | `sync` в Gcore по таймеру |
| gistrec-cloud | **Gcore** (`mysql-backup.service` на finland-01) | — | нет, это уже оригинал |
| gistrec-share | **Gcore** (`s3-rclone copyto … gc:gistrec-share/…`, README) | share.gistrec.cloud → Gcore | нет |
| clear-transcript-bot | Яндекс | Яндекс | **нет** — в Gcore пустой бакет, при переключении бот стартует с нуля (решение 11.10) |

Переключённые бакеты в `BUCKETS` скрипта не входят: `sync` удалил бы в Gcore
всё, чего нет в Яндексе, а `copy` вернул бы удалённое.

## Таймер и ручной запуск

На finland-01 роль ставит `/usr/local/sbin/s3-rclone` (remote'ы `yc:` `gc:`
`gcb:` из `/root/s3-mirror.env`), `/usr/local/sbin/s3-mirror.sh` и
`s3-mirror.timer` (`*-*-* 00/6:30`, `sync`). Оба скрипта — копии из `scripts/`.

```bash
ssh finland-01 'systemctl list-timers s3-mirror.timer; sudo journalctl -u s3-mirror.service -n 20'
ssh finland-01 'sudo s3-mirror.sh size'          # объём и число объектов с обеих сторон
ssh finland-01 'sudo systemctl start s3-mirror.service'   # внеочередной проход
ssh finland-01 'sudo s3-rclone lsd gc:'          # любая команда rclone
```

Маркер успешного прохода — `/var/lib/s3-mirror/.last-success` (под алерт
свежести, как у бэкапов; алерта пока нет).

Ключи в vault: `vault_s3_mirror_yc_*` (SA `s3-mirror`, `storage.viewer`),
`vault_gcore_s3_*` (storage «gistrec»), `vault_mysql_backup_s3_*` (storage
«gistrec-backups», общие с бэкапами).

## Если Яндекс лёг: переключение

Везде endpoint `https://s-ed1.cloud.gcore.lu`, region `s-ed1`, имя бакета то
же, ключи storage «gistrec». Откат — вернуть старые значения.

Порядок для каждого бакета, строго до смены endpoint'а: `systemctl stop
s3-mirror.timer s3-mirror.service` → при живом Яндексе остановить приложение и
сделать финальный `s3-mirror.sh sync` → убрать бакет из `BUCKETS` в
`scripts/s3-mirror.sh` и задеплоить роль → переключить приложение → вернуть
таймер. Иначе ближайший `sync` удалит в Gcore всё, что приложение записало
только туда, и откатит изменённое.

1. **glucose-bot** (finland-01, `~/GlucoseBot/.env`): `S3_ENDPOINT`,
   `S3_REGION`, `S3_ACCESS_KEY`, `S3_SECRET_KEY`; `pm2 restart glucose-bot --update-env`.
2. **dnd-crime-api** (finland-01, `~/DndCrime/backend/.env`): `S3_ENDPOINT`,
   `S3_ACCESS_KEY`, `S3_SECRET_KEY`, `S3_PUBLIC_BASE_URL=https://s-ed1.cloud.gcore.lu/dnd-crime`.
3. **askads** (`~/askads/.env` на обоих хостах): `S3_ENDPOINT`, `S3_REGION`,
   `S3_ACCESS_KEY_ID`, `S3_SECRET_ACCESS_KEY`, `S3_PUBLIC_BASE=https://s-ed1.cloud.gcore.lu/askads`.
4. **recepter** (russia-03): в `101edok/backend` `common/s3.py` endpoint и
   `S3_PUBLIC_URL` зашиты в код — `https://s-ed1.cloud.gcore.lu/` и
   `https://recepter.s-ed1.cloud.gcore.lu/`; ключи в `.env` (`S3_ACCESS_KEY`,
   `S3_SECRET_KEY`). Превью `<версия>.edalle.ru`: в `edalle-ru.conf` host
   `storage.yandexcloud.net` → `s-ed1.cloud.gcore.lu` (две строки), деплой nginx
   на russia-03. CI `101edok/front` кладёт релизы по S3-ключу — endpoint там же.
5. **aleksandravoo** — `.github/workflows/preview.yml`: `--endpoint-url`,
   `AWS_REGION`, шаблон raw-ссылок `https://${BUCKET}.s-ed1.cloud.gcore.lu/…`;
   secrets `YC_S3_ACCESS_KEY_ID` / `YC_S3_SECRET_ACCESS_KEY`.
6. **clear-transcript-bot** — `S3_ENDPOINT`, `S3_ACCESS_KEY`, `S3_SECRET_KEY`;
   бакет пустой, старые записи теряют аудио.

Перед 2–4 проверить, не хранит ли БД приложения полные URL с
`storage.yandexcloud.net`: их надо переписать на новый host одним UPDATE.

## История и грабли

- 11.10 15:17–15:49 первая копия (≈35 ГБ без ctb, ~30 мин); бэкапы MySQL и
  share переведены на Gcore в тот же день; превью edalle возвращены на Яндекс
  (CI пишет туда), решение — зеркало по таймеру вместо переключения.
- `pkill -f s3-mirror` из ssh-сессии убивает саму сессию — её командная строка
  содержит ту же подстроку, а `pkill -x rclone` заодно убьёт загрузку бэкапов
  MySQL/CH, если она идёт в этот момент. Останавливать `systemctl stop
  s3-mirror.service`, ручной запуск — `kill` конкретного PID из `pgrep -a rclone`.
- Ключи с `//` (`recepter/releases/android//app-release.apk/src/…`, 307 штук,
  исходники, залитые под путь apk) rclone не читает: Яндекс отвечает на них
  не-XML ошибкой. Исключены в скрипте, в копии их нет.
- Удалённое имя бакета в Gcore занято ещё ~20 с: apply после удаления даёт `409`.
- `api.gcore.com` из РФ не отвечает по TLS — terraform через
  `ssh -f -N -D 127.0.0.1:1081 finland-01` и `HTTPS_PROXY=socks5://127.0.0.1:1081`.
- Vault-переменная, заданная дважды, берётся последней; `ansible-vault` читает
  `.vault_pass` только из `ansible/` (ansible.cfg); через `!` нужен `2>/dev/null`.

## Хвосты

- ClickHouse-бэкап: у роли нет тега, env приедет полным деплоем finland-01;
  до этого идёт в Яндекс старым ключом. После — отозвать старый ключ SA
  `mysql-backup`.
- Lifecycle в Gcore: gistrec-cloud 365d (в Яндексе было правилом на бакете),
  через boto3 из venv ctb, как в `s3-public-policy.py`. На recepter правило
  `releases/` 90d уже стоит с обеих сторон (Яндекс —
  `terraform/yandex/recepter-lifecycle.json`); glucose-bot без ретеншна
  намеренно.
- Алерт свежести на `/var/lib/s3-mirror/.last-success` (go.d filecheck, как у
  бэкапов).
- Бакет askads создан руками 2026-09-19 и в `terraform/yandex` не описан.
