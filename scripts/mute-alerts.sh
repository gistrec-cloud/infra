#!/usr/bin/env bash
# Заглушить уведомления netdata (Telegram, чаты проектов, Pushover) на всём
# парке на время работ — например, ребута: при нём кричит не сам узел, а
# парент и соседи с кросс-пробами, поэтому файл заглушки ложится на все узлы.
#
# Usage:
#   scripts/mute-alerts.sh 20m "ребут finland-01"   # Nm или Nh, не больше 2h
#   scripts/mute-alerts.sh --off                    # снять досрочно
#   scripts/mute-alerts.sh --status                 # что стоит на узлах
#
# Заглушка истекает сама: срок лежит в файле, его сверяет
# health_alarm_notify.conf. После срока (или --off) alarm-telegram --sweep в
# течение двух минут присылает всё, что ещё горит, и удаляет файл. Узел,
# недоступный при включении, не заглушён — скрипт скажет об этом и вернёт 1.
set -euo pipefail

FILE="${MUTE_ALERTS_FILE:-/var/cache/netdata/alarm-mute}"
MAX=7200

usage() { sed -n '2,13p' "$0" | sed 's/^# \{0,1\}//' >&2; exit 1; }

mode=on
case "${1:-}" in
  --off) mode=off; [ $# -eq 1 ] || usage ;;
  --status) mode=status; [ $# -eq 1 ] || usage ;;
  *) [ $# -eq 2 ] && [ -n "$2" ] || usage ;;
esac

if [ "$mode" = on ]; then
  case "$1" in
    *[!0-9]*m|*[!0-9]*h|m|h) usage ;;
    *m) secs=$(( ${1%m} * 60 )) ;;
    *h) secs=$(( ${1%h} * 3600 )) ;;
    *) usage ;;
  esac
  [ "$secs" -gt 0 ] || usage
  [ "$secs" -le "$MAX" ] || { echo "FAIL: не больше 2h — заглушку легко забыть" >&2; exit 1; }
  case "$2" in *$'\n'*) echo "FAIL: причина — одной строкой" >&2; exit 1 ;; esac
fi

cd "$(dirname "$0")/../ansible"

# Фиктивный пароль vault: в host vars ничего не зашифровано, а настоящий — это
# `op read` и Touch ID на каждый запуск (тот же приём, что в backup-envs.sh).
vpf=$(mktemp)
echo mute-alerts-dummy > "$vpf"
trap 'rm -f "$vpf"' EXIT

now=$(date +%s)
# Вывод ansible — через переменную: напрямую он ломает stdio у `!`-команд Claude Code.
run() { # <module> <args> — печатает блок на узел («host | CHANGED …»), код возврата ansible
  local out rc=0
  # shellcheck disable=SC2086  # MUTE_ALERTS_ANSIBLE — намеренно несколько аргументов
  out=$(ANSIBLE_VAULT_PASSWORD_FILE="$vpf" ANSIBLE_DEPRECATION_WARNINGS=false ansible ${MUTE_ALERTS_ANSIBLE:-all} -m "$1" -a "$2" 2>&1 </dev/null) || rc=$?
  printf '%s\n' "$out"
  return "$rc"
}
OK='^[^ ]+ \| (CHANGED|SUCCESS)'
BAD='^[^ ]+ \| (UNREACHABLE|FAILED)'
hhmm() { TZ=Europe/Moscow date -r "$1" +%H:%M 2>/dev/null || TZ=Europe/Moscow date -d "@$1" +%H:%M; }

case "$mode" in
  on)
    until=$(( now + secs ))
    args=$(python3 -c 'import json, sys
print(json.dumps({"content": f"{sys.argv[1]}\n{sys.argv[2]}\n", "dest": sys.argv[3], "mode": "0644"}))' "$until" "$2" "$FILE")
    if out=$(run ansible.builtin.copy "$args"); then
      grep -cE "$OK" <<<"$out" | xargs printf 'заглушено узлов: %s\n'
      echo "до $(hhmm "$until") МСК: $2"
    else
      grep -E "$BAD" <<<"$out" | cut -d' ' -f1-3 >&2 || true
      echo "FAIL: заглушка легла не на все узлы (см. выше) — с них уведомления пойдут" >&2
      exit 1
    fi
    ;;
  off)
    # Не удаляем, а сдвигаем срок на «сейчас»: уборка дошлёт горящее и снимет файл сама.
    out=$(run ansible.builtin.shell "[ ! -f $FILE ] || sed -i.bak '1s/.*/$now/' $FILE && rm -f $FILE.bak") \
      || { grep -E "$BAD" <<<"$out" | cut -d' ' -f1-3 >&2 || true
           echo "WARN: не до всех узлов дошло — там заглушка истечёт по своему сроку" >&2; }
    echo "заглушка снята; что ещё горит, придёт в Telegram в течение 2 минут"
    ;;
  status)
    out=$(run ansible.builtin.shell "cat $FILE 2>/dev/null || echo none") || true
    python3 -c 'import re, sys, time
now, host = time.time(), None
blocks = {}
for line in sys.stdin.read().splitlines():
    m = re.match(r"(\S+) \| (\w+)", line)
    if m:
        host = m.group(1)
        blocks[host] = [m.group(2)]
    elif host:
        blocks[host].append(line)
for host, (state, *body) in sorted(blocks.items()):
    if state not in ("CHANGED", "SUCCESS"):
        print(f"{host}: недоступен")
    elif not body or not body[0].isdigit():
        print(f"{host}: нет заглушки")
    else:
        left = int(body[0]) - now
        tail = f"ещё {int(left // 60) + 1} мин" if left > 0 else "срок вышел, ждёт досылки"
        print(f"{host}: {tail}" + (f" ({body[1]})" if len(body) > 1 and body[1] else ""))' <<<"$out"
    ;;
esac
