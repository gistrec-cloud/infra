#!/usr/bin/env python3
"""CRITICAL-алерты, по которым netdata не отправила уведомление, → Telegram.

netdata ненадёжно сообщает об алерте, родившемся сразу в CRITICAL
(UNINITIALIZED → CRITICAL): после старта агента и при переподключении ребёнка
переход то уходит, то нет. API Директа 14–16.10.2026 так пролежал 2.5 дня,
low_price_flights 22.10 — 6 часов. Раз в 2 минуты (unnotified-alarms.timer)
берём активные CRITICAL всех хостов парента и по netdata-meta.db проверяем,
запускался ли alarm-notify хоть раз за текущий эпизод (с последнего CLEAR или
WARNING; рестарты и переподключения эпизод не прерывают). API alarm_log не
годится: в нём 1000 записей, после рестарта их перетирает churn за минуты.

Каждый переход сообщается один раз; отмеченным считается только после удачной
отправки, так что сбой Telegram (ТСПУ) повторится на следующем прогоне."""
import json
import os
import re
import sqlite3
import time
import urllib.parse
import urllib.request

API = "http://127.0.0.1:19999"
DB = "file:/var/cache/netdata/netdata-meta.db?mode=ro"
NOTIFY_CONF = "/etc/netdata/health_alarm_notify.conf"
STATE = os.path.join(os.environ.get("STATE_DIRECTORY", "/var/lib/unnotified-alarms"), "seen.json")
CLEAR, WARNING, CRITICAL = 1, 3, 4
# Запас поверх delay up: alarm-notify стартует не мгновенно.
GRACE = 120


def get(path):
    with urllib.request.urlopen(API + path, timeout=15) as r:
        return json.load(r)


def unsent_episode(db, host, alarm_id, until=None):
    """(transition_id, when, delay_up_to) последнего перехода в CRITICAL, если за
    эпизод не было ни одного уведомления, иначе None."""
    rows = db.execute(
        """select hex(d.transition_id), d.new_status, d.exec_run_timestamp,
                  d.when_key, d.delay_up_to_timestamp
           from health_log h join health_log_detail d using(health_log_id)
           join host using(host_id)
           where host.hostname = ? and h.alarm_id = ? and d.when_key <= ?
           order by d.when_key desc, d.unique_id desc limit 50""",
        (host, alarm_id, until or 2**62),
    ).fetchall()
    if not rows or rows[0][1] != CRITICAL:
        return None
    for _, status, exec_run, _, _ in rows:
        if status == CRITICAL and exec_run:
            return None
        if status in (CLEAR, WARNING):
            break
    return rows[0][0], rows[0][3], rows[0][4] or 0


def unnotified(db, now):
    for host in get("/api/v1/info")["mirrored_hosts"]:
        alarms = get(f"/host/{urllib.parse.quote(host)}/api/v1/alarms")["alarms"]
        for a in alarms.values():
            if a["status"] != "CRITICAL" or a["recipient"] == "silent" or a["silenced"]:
                continue
            ep = unsent_episode(db, host, a["id"])
            if ep and now - max(ep[1], ep[2]) >= GRACE:
                yield ep[0], host, a


def send(conf, text):
    token = re.search(r'^TELEGRAM_BOT_TOKEN="([^"]+)"', conf, re.M).group(1)
    chat = re.search(r'^DEFAULT_RECIPIENT_TELEGRAM="([^"|]+)', conf, re.M).group(1)
    data = urllib.parse.urlencode({"chat_id": chat, "text": text}).encode()
    url = f"https://api.telegram.org/bot{token}/sendMessage"
    for attempt in range(3):
        try:
            with urllib.request.urlopen(url, data, timeout=20) as r:
                return json.load(r)["ok"]
        except OSError:
            time.sleep(5 * (attempt + 1))
    return False


def main():
    now = int(time.time())
    db = sqlite3.connect(DB, uri=True, timeout=10)
    found = {tid: (host, a) for tid, host, a in unnotified(db, now)}
    try:
        with open(STATE) as f:
            seen = set(json.load(f))
    except (OSError, ValueError):
        seen = set()
    new = {tid: v for tid, v in found.items() if tid not in seen}
    if new:
        lines = [
            f"• {host}: {a['name']} = {a['value_string']}\n  {a['chart']}\n  {a['info']}"
            for host, a in new.values()
        ]
        text = (
            "🔴 CRITICAL без уведомления — алерт загорелся при старте netdata "
            "или переподключении хоста, обычное сообщение не ушло:\n\n" + "\n\n".join(lines)
        )
        with open(NOTIFY_CONF) as f:
            conf = f.read()
        if not send(conf, text):
            raise SystemExit("telegram send failed")
    # Храним только ещё активные: позеленевший и снова «родившийся» алерт —
    # новый переход с новым transition_id.
    with open(STATE + ".tmp", "w") as f:
        json.dump(sorted((seen & set(found)) | set(new)), f)
    os.replace(STATE + ".tmp", STATE)


if __name__ == "__main__":
    main()
