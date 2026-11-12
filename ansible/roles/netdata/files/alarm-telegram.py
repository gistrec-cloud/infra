#!/usr/bin/env python3
"""Telegram-уведомление netdata, которое живёт одним сообщением на эпизод.

Стоковый send_telegram шлёт новое сообщение на каждый переход, и по
«🔴 ... is critical» не видно, кончилось ли: «recovered» теряется в ленте, а
алерт, родившийся в CRITICAL, его порой не получает вовсе. Здесь CRITICAL (или
WARNING для роли без |critical) открывает эпизод новым сообщением со временем
начала, а следующие переходы редактируют его: CLEAR дописывает, когда решено и
сколько длилось. Переход в CRITICAL из уже открытого не-CRITICAL эпизода — новое
сообщение ответом на старое: редактирование не звонит, а CRITICAL должен.

Вызывается из custom_sender (health_alarm_notify.conf) с переменными
alarm-notify.sh в окружении; аргументы — chat id после фильтра |critical.
Эпизод — файл в $NETDATA_CACHE_DIR/alarm-telegram на пару (chat, host, alarm_id).

Чаты проектов. Если аларм относится к проекту из файла маршрутов
(alarmroutes.ROUTES, роль выводит его из alert_chats реестра) и это аларм
простоя (alarmroutes.is_simple), то же событие уходит и в чаты проекта: только
CRITICAL и его закрытие, своим текстом — без ноды, чарта и ссылки на netdata
(она за авторизацией). Эпизод у каждого чата свой. Сбой чата проекта не влияет
на код возврата: он — про чаты владельца из argv."""
import fcntl
import html
import json
import os
import sys
import time
import urllib.error
import urllib.parse
import urllib.request
from datetime import datetime
from zoneinfo import ZoneInfo

# Общий модуль маршрутов роль ставит в /usr/local/lib/netdata-alarms; без него
# (ребёнок, старый деплой) скрипт работает как раньше, только для чатов владельца.
sys.path[:0] = [os.environ.get("ALARM_LIB_DIR", "/usr/local/lib/netdata-alarms"),
                os.path.dirname(os.path.abspath(__file__))]
try:
    import alarmroutes
except ImportError:  # pragma: no cover — нет модуля, нет и маршрутов
    alarmroutes = None

STATE_DIR = os.path.join(os.environ.get("NETDATA_CACHE_DIR", "/var/cache/netdata"), "alarm-telegram")
TZ = ZoneInfo("Europe/Moscow")
EMOJI = {"CRITICAL": "🔴", "WARNING": "⚠️", "CLEAR": "✅"}
STATUS = {"CRITICAL": "is critical", "WARNING": "needs attention", "CLEAR": "recovered"}

env = os.environ.get


def api(method, **params):
    url = f"{env('TELEGRAM_API_URL') or 'https://api.telegram.org'}/bot{env('TELEGRAM_BOT_TOKEN')}/{method}"
    data = urllib.parse.urlencode(params).encode()
    for attempt in range(3):
        try:
            with urllib.request.urlopen(url, data, timeout=20) as r:
                return json.load(r)["result"]
        except urllib.error.HTTPError as e:
            # Тот же текст повторно (алерт перевзвёлся рестартом) — уже показан.
            if e.code == 400 and b"message is not modified" in e.read():
                return None
            # Прочие 4xx (сообщение удалено) повтором не лечатся.
            if e.code != 429 and e.code < 500:
                raise
        except OSError:
            pass
        time.sleep(5 * (attempt + 1))
    raise OSError(f"telegram {method}: no response")


def stamp(ts):
    return datetime.fromtimestamp(ts, TZ).strftime("%d.%m %H:%M")


def human(seconds):
    m = max(1, round(seconds / 60))
    if m < 60:
        return f"{m} мин"
    h, m = divmod(m, 60)
    if h < 24:
        return f"{h} ч {m} мин" if m else f"{h} ч"
    d, h = divmod(h, 24)
    return f"{d} д {h} ч" if h else f"{d} д"


def render(ep, status, now):
    """Текст сообщения по эпизоду и текущему статусу."""
    e = html.escape
    title = env("name", "").replace("_", " ")
    summary = (env("summary") or title).replace("_", " ")
    value = ep["value"] if status == "CLEAR" else env("value_string", "")
    link = summary
    if value:
        link += f" (было {value})" if status == "CLEAR" else f" = {value}"
    lines = [
        f"{EMOJI.get(status, '⚪️')} {e(env('host', ''))} {STATUS.get(status, status.lower())} - <b>{e(title)}</b>",
        e(env("chart", "")),
        f'<a href="{e(env("goto_url", ""), quote=True)}">{e(link)}</a>',
        f"<i>{e(env('info', ''))}</i>",
        "",
        f"🕒 Началось: {stamp(ep['start'])} МСК",
    ]
    if status == "CLEAR":
        lines += [f"✅ Решено: {stamp(now)} МСК", f"⏱ Длилось: {human(now - ep['start'])}"]
    else:
        if status == "WARNING" and ep["peak"] == "CRITICAL":
            lines.append(f"⚠️ Снизилось до warning: {stamp(now)} МСК")
        lines.append("⏳ Ещё не решено")
    return "\n".join(lines)


def render_owner(ep, status, now):
    text = render(ep, "CLEAR" if status == "REMOVED" else status, now)
    if status == "REMOVED":
        text = text.replace("✅ Решено", "⚪️ Алерт удалён", 1)
    return text


def project_view(route):
    """Текст для чата проекта: что лежит и почему, без ноды, чарта и ссылки."""
    def view(ep, status, now):
        e = html.escape
        why = alarmroutes.cause(route, env("name", ""), env("chart", ""), env("summary", ""), env("info", ""))
        name = e(route["name"])
        if status == "CRITICAL":
            return "\n".join([f"🔴 <b>{name}</b> недоступен — {e(why)}", "",
                              f"🕒 Началось: {stamp(ep['start'])} МСК"])
        head = f"✅ <b>{name}</b> снова работает" if status == "CLEAR" else f"⚪️ <b>{name}</b>: проверка снята"
        end = "✅ Восстановлено" if status == "CLEAR" else "⚪️ Проверка снята"
        return "\n".join([head, f"Было: {e(why)}", "",
                          f"🕒 Началось: {stamp(ep['start'])} МСК",
                          f"{end}: {stamp(now)} МСК",
                          f"⏱ Длилось: {human(now - ep['start'])}"])
    return view


def notify(chat, status, now, view=render_owner, quiet_clear=True):
    """quiet_clear: CLEAR без открытого эпизода всё равно сообщить (тихо).
    Чату проекта такое не шлём — «восстановлено» без начала его только путает."""
    key = f"{chat}_{env('host', '')}_{env('alarm_id', '')}".replace("/", "_")
    path = os.path.join(STATE_DIR, key)
    with open(os.path.join(STATE_DIR, ".lock"), "w") as lock:
        # Переходы одного алерта могут прийти почти разом — по одному.
        fcntl.flock(lock, fcntl.LOCK_EX)
        try:
            with open(path) as f:
                ep = json.load(f)
        except (OSError, ValueError):
            ep = None

        chat_id, _, thread = chat.partition(":")
        base = {"chat_id": chat_id, "parse_mode": "HTML", "disable_web_page_preview": "true"}
        if thread:
            base["message_thread_id"] = thread

        if status in ("CRITICAL", "WARNING"):
            raise_new = ep is None or (status == "CRITICAL" and ep["peak"] != "CRITICAL")
            if raise_new:
                reply_to = ep and ep["message_id"]
                ep = {"start": ep["start"] if ep else int(env("when") or now), "peak": status}
            ep["value"] = env("value_string", "")
            if status == "CRITICAL":
                ep["peak"] = "CRITICAL"
            text = view(ep, status, now)
            if not raise_new:
                try:
                    api("editMessageText", message_id=ep["message_id"], text=text, **base)
                except urllib.error.HTTPError:
                    raise_new, reply_to = True, None  # сообщение удалили — шлём заново
            if raise_new:
                extra = {}
                if reply_to:
                    extra["reply_parameters"] = json.dumps({"message_id": reply_to, "allow_sending_without_reply": True})
                ep["message_id"] = api("sendMessage", text=text, **base, **extra)["message_id"]
            with open(path + ".tmp", "w") as f:
                json.dump(ep, f)
            os.replace(path + ".tmp", path)
            return

        # CLEAR / REMOVED закрывают эпизод. Без записи (уведомление о начале
        # не ушло или state потерян) — отдельное тихое сообщение, как раньше.
        if ep is None:
            if not quiet_clear:
                return
            ep = {"start": now - int(env("non_clear_duration") or 0), "value": env("old_value_string", "")}
        text = view(ep, status, now)
        try:
            if "message_id" not in ep:
                raise LookupError
            api("editMessageText", message_id=ep["message_id"], text=text, **base)
        except (LookupError, urllib.error.HTTPError):
            api("sendMessage", text=text, disable_notification="true", **base)
        try:
            os.remove(path)
        except FileNotFoundError:
            pass


def project_chats(owner):
    """(маршрут, чаты) проекта, если аларм — простой этого проекта, иначе (None, [])."""
    if alarmroutes is None:
        return None, []
    route = alarmroutes.route_for(alarmroutes.load(os.environ.get("ALARM_ROUTES", alarmroutes.ROUTES))["routes"],
                                  env("name", ""), env("chart", ""), env("src", ""))
    if not route or not alarmroutes.is_simple(route, env("name", "")):
        return None, []
    # Чат и так в argv (владелец вписал свой чат проекту) — второй раз не шлём.
    return route, [c for c in route.get("chats", []) if c not in owner]


def main():
    status = env("status", "")
    now = int(env("when") or time.time())
    os.makedirs(STATE_DIR, exist_ok=True)
    owner = sys.argv[1:]
    failed = 0
    for chat in owner:
        try:
            notify(chat, status, now)
        except Exception as e:  # noqa: BLE001 — один чат не должен ронять остальные
            print(f"alarm-telegram: {chat}: {e}", file=sys.stderr)
            failed += 1
    # Чаты проекта: только CRITICAL и его закрытие. WARNING после CRITICAL
    # эпизод не трогает — сообщение ждёт CLEAR.
    if status in ("CRITICAL", "CLEAR", "REMOVED"):
        try:
            route, chats = project_chats(owner)
        except Exception as e:  # noqa: BLE001 — битые маршруты не мешают владельцу
            print(f"alarm-telegram: routes: {e}", file=sys.stderr)
            route, chats = None, []
        for chat in chats:
            try:
                notify(chat, status, now, view=project_view(route), quiet_clear=False)
            except Exception as e:  # noqa: BLE001
                print(f"alarm-telegram: {route['name']} {chat}: {e}", file=sys.stderr)
    # Код возврата — про чаты владельца: их провал должен быть виден.
    sys.exit(1 if failed == len(owner) else 0)


if __name__ == "__main__":
    main()
