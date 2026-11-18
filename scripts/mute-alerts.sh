#!/usr/bin/env bash
# Заглушить уведомления netdata (Telegram, чаты проектов, Pushover) на всём
# парке на время работ — например, ребута: при нём кричит не сам узел, а
# парент и соседи с кросс-пробами, поэтому файл заглушки ложится на все узлы.
#
# Usage:
#   scripts/mute-alerts.sh 20m "ребут finland-01"   # Nm или Nh, не больше 2h
#   scripts/mute-alerts.sh --at 01:58 40m "ребут"   # включить позже (МСК, ближайшие сутки)
#   scripts/mute-alerts.sh --off                    # снять досрочно, отменить запланированную
#   scripts/mute-alerts.sh --status                 # что стоит на узлах
#
# Заглушка истекает сама: срок лежит в файле, его сверяет
# health_alarm_notify.conf. После срока (или --off) alarm-telegram --sweep в
# течение двух минут присылает всё, что ещё горит, и удаляет файл. Узел,
# недоступный при включении, не заглушён — скрипт скажет об этом и вернёт 1.
#
# --at: на узел ложится заготовка файла ($FILE.next) и разовый таймер systemd
# alarm-mute-at, который в назначенную минуту ставит её на место. Таймер живёт
# на самом узле, поэтому ноутбук к этому времени может спать.
set -euo pipefail

FILE="${MUTE_ALERTS_FILE:-/var/cache/netdata/alarm-mute}"
MAX=7200

usage() { sed -n '2,14p' "$0" | sed 's/^# \{0,1\}//' >&2; exit 1; }

mode=on at=""
if [ "${1:-}" = --at ]; then
  [ $# -eq 4 ] || usage
  at=$2
  shift 2
fi
case "${1:-}" in
  --off) mode=off; [ $# -eq 1 ] && [ -z "$at" ] || usage ;;
  --status) mode=status; [ $# -eq 1 ] && [ -z "$at" ] || usage ;;
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
start=$now
if [ -n "$at" ]; then
  # Ближайшие HH:MM по Москве: узлы могут жить в другом поясе, им уходит unix-время.
  start=$(python3 -c 'import sys, time
from datetime import datetime, timedelta
from zoneinfo import ZoneInfo
now = datetime.now(ZoneInfo("Europe/Moscow"))
t = datetime.strptime(sys.argv[1], "%H:%M")
d = now.replace(hour=t.hour, minute=t.minute, second=0, microsecond=0)
print(int((d if d > now else d + timedelta(days=1)).timestamp()))' "$at") \
    || { echo "FAIL: время — HH:MM по Москве" >&2; exit 1; }
fi
TIMER=alarm-mute-at
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
    until=$(( start + secs ))
    # третья строка (начало) нужна только --status: узлы читают первые две
    args=$(python3 -c 'import json, sys
print(json.dumps({"content": f"{sys.argv[1]}\n{sys.argv[2]}\n{sys.argv[4]}\n", "dest": sys.argv[3], "mode": "0644"}))' \
      "$until" "$2" "$FILE${at:+.next}" "$start")
    if out=$(run ansible.builtin.copy "$args") && { [ -z "$at" ] || out=$(run ansible.builtin.shell \
        "systemctl stop $TIMER.timer 2>/dev/null; systemctl reset-failed $TIMER.service 2>/dev/null; systemd-run --unit=$TIMER --on-calendar=@$start --timer-property=AccuracySec=1s mv $FILE.next $FILE"); }; then
      grep -cE "$OK" <<<"$out" | xargs printf '%s узлов: %s\n' "$([ -n "$at" ] && echo запланировано || echo заглушено)"
      echo "${at:+с $(hhmm "$start") }до $(hhmm "$until") МСК: $2"
    else
      grep -E "$BAD" <<<"$out" | cut -d' ' -f1-3 >&2 || true
      echo "FAIL: заглушка легла не на все узлы (см. выше) — с них уведомления пойдут" >&2
      exit 1
    fi
    ;;
  off)
    # Не удаляем, а сдвигаем срок на «сейчас»: уборка дошлёт горящее и снимет файл сама.
    out=$(run ansible.builtin.shell "systemctl stop $TIMER.timer 2>/dev/null; rm -f $FILE.next; [ ! -f $FILE ] || sed -i.bak '1s/.*/$now/' $FILE && rm -f $FILE.bak") \
      || { grep -E "$BAD" <<<"$out" | cut -d' ' -f1-3 >&2 || true
           echo "WARN: не до всех узлов дошло — там заглушка истечёт по своему сроку" >&2; }
    echo "заглушка снята; что ещё горит, придёт в Telegram в течение 2 минут"
    ;;
  status)
    out=$(run ansible.builtin.shell "cat $FILE 2>/dev/null || echo none; echo ---; cat $FILE.next 2>/dev/null; echo ---; systemctl is-active $TIMER.timer 2>/dev/null || true") || true
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
msk = lambda ts: time.strftime("%H:%M", time.gmtime(int(ts) + 10800))
for host, (state, *body) in sorted(blocks.items()):
    if state not in ("CHANGED", "SUCCESS"):
        print(f"{host}: недоступен")
        continue
    parts = [[]]
    for x in body:
        parts.append([]) if x == "---" else parts[-1].append(x)
    cur, nxt, timer = [(x + [""] * 3)[:3] for x in (parts + [[], []])[:3]]
    if not cur[0].isdigit():
        line = "нет заглушки"
    else:
        left = int(cur[0]) - now
        line = f"ещё {int(left // 60) + 1} мин" if left > 0 else "срок вышел, ждёт досылки"
        line += f" ({cur[1]})" if cur[1] else ""
    if nxt[0].isdigit():
        line += f"; запланирована {msk(nxt[2])}–{msk(nxt[0])} МСК ({nxt[1]})"
        line += "" if timer[0] == "active" else ", НО ТАЙМЕР НЕ АКТИВЕН"
    print(f"{host}: {line}")' <<<"$out"
    ;;
esac
