#!/usr/bin/env bash
# rclone с remote'ами из /root/s3-mirror.env, без rclone.conf на диске:
#   yc:  Yandex Object Storage (ключ на чтение, SA s3-mirror)
#   gc:  Gcore storage «gistrec» (бакеты приложений)
#   gcb: Gcore storage «gistrec-backups» (gistrec-cloud)
# Пример: s3-rclone size gc:recepter
set -euo pipefail
# shellcheck disable=SC1090
. "${ENV_FILE:-/root/s3-mirror.env}"
export RCLONE_CONFIG_YC_TYPE=s3 RCLONE_CONFIG_YC_PROVIDER=Other
export RCLONE_CONFIG_YC_ENDPOINT=https://storage.yandexcloud.net RCLONE_CONFIG_YC_REGION=ru-central1
export RCLONE_CONFIG_YC_ACCESS_KEY_ID="${YC_ACCESS_KEY:-}" RCLONE_CONFIG_YC_SECRET_ACCESS_KEY="${YC_SECRET_KEY:-}"
export RCLONE_CONFIG_GC_TYPE=s3 RCLONE_CONFIG_GC_PROVIDER=Other
export RCLONE_CONFIG_GC_ENDPOINT=https://s-ed1.cloud.gcore.lu RCLONE_CONFIG_GC_REGION=s-ed1
export RCLONE_CONFIG_GC_ACCESS_KEY_ID="${GC_ACCESS_KEY:-}" RCLONE_CONFIG_GC_SECRET_ACCESS_KEY="${GC_SECRET_KEY:-}"
export RCLONE_CONFIG_GCB_TYPE=s3 RCLONE_CONFIG_GCB_PROVIDER=Other
export RCLONE_CONFIG_GCB_ENDPOINT=https://s-ed1.cloud.gcore.lu RCLONE_CONFIG_GCB_REGION=s-ed1
export RCLONE_CONFIG_GCB_ACCESS_KEY_ID="${GCB_ACCESS_KEY:-}" RCLONE_CONFIG_GCB_SECRET_ACCESS_KEY="${GCB_SECRET_KEY:-}"
exec rclone "$@"
