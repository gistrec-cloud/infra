#!/usr/bin/env bash
# Зеркало Yandex Object Storage → Gcore. Запускать на finland-01 от root; remote'ы
# и ключи — в s3-rclone (/root/s3-mirror.env), см. docs/runbooks/s3-mirror.md.
#
#   s3-mirror.sh copy   # докладывает недостающее
#   s3-mirror.sh sync   # перед cutover: ещё и удаляет лишнее в Gcore
#   s3-mirror.sh size   # сверка объёмов и числа объектов с обеих сторон
set -euo pipefail

MODE="${1:-copy}"
RCLONE="${RCLONE:-/usr/local/sbin/s3-rclone}"

# бакет:remote-назначения. clear-transcript-bot намеренно нет: в Gcore только пустой
# бакет под быстрое переключение (user, 11.10). Публичность — bucket policy
# (scripts/s3-public-policy.py), ACL на объектах не нужен.
# Переключённые бакеты убраны (gistrec-share, gistrec-cloud — 11.10): их пишут уже в Gcore.
BUCKETS="aleksandravoo:gc askads:gc dnd-crime:gc glucose-bot:gc recepter:gc"

for spec in $BUCKETS; do
  b="${spec%%:*}" dst="${spec##*:}"
  case "$MODE" in
    size)
      echo "== $b"
      printf 'yc   '; "$RCLONE" size "yc:$b" --fast-list
      printf '%-4s ' "$dst"; "$RCLONE" size "$dst:$b" --fast-list
      ;;
    copy|sync)
      echo "== $(date -Is) $MODE $b → $dst"
      # --size-only: ETag у multipart-объектов не md5, а modtime стоил бы HEAD на каждый объект.
      # --timeout: без него зависшее чтение из Яндекса стояло молча (11.10, recepter).
      # -v: без него rclone не пишет статистику, пока ничего не передано.
      # --exclude: ключи с «//» под releases/android Яндекс не отдаёт (SerializationError).
      "$RCLONE" "$MODE" "yc:$b" "$dst:$b" --size-only --fast-list \
        --exclude 'releases/android//**' \
        --transfers 16 --checkers 32 --retries 3 --low-level-retries 5 \
        --timeout 2m --contimeout 30s -v --stats 60s --stats-one-line
      ;;
    *) echo "usage: $0 copy|sync|size" >&2; exit 2 ;;
  esac
done

# Маркер свежести (как у бэкапов): set -e не дал бы дойти сюда после ошибки.
[ "$MODE" = size ] || { mkdir -p /var/lib/s3-mirror && touch /var/lib/s3-mirror/.last-success; }
