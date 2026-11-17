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
на код возврата: он — про чаты владельца из argv.

Уборка (--sweep, alarm-telegram-sweep.timer). CLEAR может не прийти вовсе:
netdata 2.12 при смене метки хоста (_is_parent — отвалились или вернулись все
дети) пересоздаёт алармы, эпизод кончается переходом UNINITIALIZED → CLEAR, а
его alarm-notify.sh не шлёт (17.11.2026: «недоступен» провисело до ручной
правки). Поэтому раз в 2 минуты открытые эпизоды сверяются с API netdata:
аларм уже CLEAR — сообщение закрывается так же, как закрыл бы его CLEAR."""
import fcntl
import html
import json
import os
import re
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
HEAD = {"CRITICAL": "🔴 Критично", "WARNING": "⚠️ Внимание", "CLEAR": "✅ Решено", "REMOVED": "⚪️ Алерт удалён"}
# 0/1-флаги: «было 1 status» ничего не говорит.
QUIET_UNITS = {"status", "boolean"}
NETDATA_API = os.environ.get("NETDATA_API", "http://127.0.0.1:19999")
NOTIFY_CONF = "/etc/netdata/health_alarm_notify.conf"
# Уборка ждёт дольше штатного пути (delay down + очередь alarm-notify + наши
# повторы), иначе опоздавший CLEAR не найдёт эпизода и пришлёт второе «решено».
SWEEP_GRACE = 180

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


def hhmm(ts, ref):
    """Время, с датой — только если день не тот, что у ref."""
    d, r = datetime.fromtimestamp(ts, TZ), datetime.fromtimestamp(ref, TZ)
    return d.strftime("%H:%M" if d.date() == r.date() else "%d.%m %H:%M")


def shown_value(v):
    if not v or env("units", "") in QUIET_UNITS or v.rsplit(" ", 1)[-1] in QUIET_UNITS:
        return ""
    return v


def render_owner(ep, status, now):
    """Сверху что случилось (summary + info), снизу одна строка «нода · время ·
    ссылка», технические имена — в свёрнутой цитате."""
    e = html.escape
    closed = status in ("CLEAR", "REMOVED")
    summary = (env("summary") or env("name", "")).replace("_", " ")
    value = shown_value(ep["value"] if closed else env("value_string", ""))
    if value:
        summary += f" (было {value})" if closed else f" = {value}"
    lines = [f"{HEAD.get(status, '⚪️ ' + status)} · <b>{e(summary)}</b>"]
    if env("info"):
        lines.append(e(env("info")))

    start = ep["start"]
    if closed:
        span = f"{hhmm(start, now)} → {hhmm(now, start)} МСК · {human(now - start)}"
    else:
        span = f"с {hhmm(start, now)} МСК"
        if status == "WARNING" and ep["peak"] == "CRITICAL":
            span += f" · снизилось до warning в {hhmm(now, start)}"
        span += " · ⏳ не решено"
    foot = [e(env("host", "")), span]
    if env("goto_url"):
        foot.append(f'<a href="{e(env("goto_url"), quote=True)}">netdata ↗</a>')
    lines += ["", " · ".join(p for p in foot if p)]

    details = [e(x) for x in (env("name", ""), env("chart", "")) if x]
    if details:
        lines.append(f"<blockquote expandable>{chr(10).join(details)}</blockquote>")
    return "\n".join(lines)


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
            ep["goto_url"] = env("goto_url", "")  # уборке ссылку взять больше неоткуда
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


def host_alarms(host):
    """{alarm_id: аларм} хоста, включая CLEAR. У парента — и по хостам детей."""
    url = f"{NETDATA_API}/host/{urllib.parse.quote(host)}/api/v1/alarms?all"
    with urllib.request.urlopen(url, timeout=15) as r:
        return {str(a["id"]): a for a in json.load(r)["alarms"].values()}


def conf_env():
    """Токен из конфига уведомлений: у таймера, в отличие от alarm-notify, окружения нет."""
    if env("TELEGRAM_BOT_TOKEN"):
        return
    with open(NOTIFY_CONF) as f:
        conf = f.read()
    for var in ("TELEGRAM_BOT_TOKEN", "TELEGRAM_API_URL"):
        m = re.search(rf'^{var}="([^"]+)"', conf, re.M)
        if m:
            os.environ[var] = m.group(1)


def sweep(now=None):
    """Закрыть эпизоды, чей аларм уже CLEAR. Только CLEAR: нет аларма или он не
    вычислен — «нет данных», а не «починилось». Возвращает число незакрытых из-за сбоя."""
    now = now or int(time.time())
    try:
        keys = sorted(k for k in os.listdir(STATE_DIR) if not k.startswith(".") and not k.endswith(".tmp"))
    except FileNotFoundError:
        return 0
    routes = alarmroutes.load(os.environ.get("ALARM_ROUTES", alarmroutes.ROUTES))["routes"] if alarmroutes else []
    by_host, failed = {}, 0
    for key in keys:
        try:
            rest, alarm_id = key.rsplit("_", 1)
            chat, host = rest.split("_", 1)
            with open(os.path.join(STATE_DIR, key)) as f:
                ep = json.load(f)
        except (OSError, ValueError):
            continue
        if host not in by_host:
            try:
                by_host[host] = host_alarms(host)
            except (OSError, ValueError, KeyError) as e:
                print(f"alarm-telegram: sweep: {host}: {e}", file=sys.stderr)
                by_host[host] = {}
        a = by_host[host].get(alarm_id)
        if not a or a.get("status") != "CLEAR":
            continue
        when = int(a.get("last_status_change") or 0)
        if now - max(when, int(a.get("delay_up_to_timestamp") or 0)) < SWEEP_GRACE:
            continue
        route = route_of(routes, a)
        view = project_view(route) if route and chat in route.get("chats", []) else render_owner
        os.environ.update(host=host, status="CLEAR", alarm_id=alarm_id, when=str(when), name=a.get("name") or "",
                          chart=a.get("chart") or "", summary=a.get("summary") or "", info=a.get("info") or "",
                          src=a.get("source") or "", units=a.get("units") or "",
                          value_string=a.get("value_string") or "", goto_url=ep.get("goto_url") or "")
        try:
            notify(chat, "CLEAR", when, view=view, quiet_clear=False)
            print(f"alarm-telegram: sweep: closed {key} ({a.get('name')})", file=sys.stderr)
        except Exception as e:  # noqa: BLE001 — Telegram недоступен: остальное в следующий прогон
            print(f"alarm-telegram: sweep: {key}: {e}", file=sys.stderr)
            failed += 1
            if isinstance(e, OSError) and not isinstance(e, urllib.error.HTTPError):
                break
    return failed


def route_of(routes, a):
    """Маршрут проекта для аларма простоя из API netdata, иначе None."""
    if alarmroutes is None:
        return None
    route = alarmroutes.route_for(routes, a.get("name") or "", a.get("chart") or "", a.get("source") or "")
    return route if route and alarmroutes.is_simple(route, a.get("name") or "") else None


def main():
    if sys.argv[1:] == ["--sweep"]:
        conf_env()
        sys.exit(1 if sweep() else 0)
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
