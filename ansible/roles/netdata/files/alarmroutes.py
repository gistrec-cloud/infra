"""Маршруты алертов в чаты проектов: общее для alarm-telegram и status-snapshot.

Файл маршрутов (/etc/netdata/alarm-telegram-routes.json) роль netdata выводит
из реестра apps.yml: у каждого приложения с alert_chats — его чаты, pm2-процессы,
префикс имён алармов и проб (ключ с дефисами → подчёркивания), список required
со страницы статуса и URL его httpcheck-проб.

В чат проекта идёт только класс «простой» — те же обязательные алармы, что
делают проект «DOWN» на странице статуса (REQUIRED в status-snapshot.py), плюс
required проекта. Метрические алармы остаются в чате владельца."""
import ipaddress
import json
import re
import urllib.parse

ROUTES = "/etc/netdata/alarm-telegram-routes.json"
# Держать в синхроне с REQUIRED в status-snapshot.py (сверяет тест).
REQUIRED = r"^(pm2_app_down|mysql_down|clickhouse_down)$|_health_down$|_healthcheck$"
PM2_CHART = re.compile(r"^app\.pm2_(.+)_(processes|mem_usage)$")
PROBE_CHART = re.compile(r"^(httpcheck|portcheck)_(.+?)\.")
# Подписи проб по-русски — как PROBE_KIND в status-snapshot.py.
PROBE_KIND = {"httpcheck": "проверка здоровья", "portcheck": "порт"}


def norm(s):
    return (s or "").lower().replace("_", "-")


def load(path=ROUTES):
    """Конфиг маршрутов; нет файла или он битый — пустой (поведение как раньше)."""
    try:
        with open(path) as f:
            cfg = json.load(f)
    except (OSError, ValueError):
        cfg = {}
    cfg.setdefault("routes", [])
    cfg.setdefault("owner_chats", [])
    cfg.setdefault("status_json", "")
    return cfg


def _key_match(key, cand):
    """val-id ↔ val-id, val-id-api (merge_prefixes: процесс и файл — по префиксу ключа)."""
    return cand == key or cand.startswith(key + "-")


def route_for(routes, name, chart, src=""):
    """Маршрут проекта, к которому относится аларм, или None.

    Как project_of страницы статуса: pm2-чарт app.pm2_<процесс>_* — по имени
    процесса (сначала явные pm2 из реестра, потом префикс ключа), иначе по
    файлу health.d из источника аларма, иначе по префиксу имени аларма или
    джобы пробы. Из нескольких подходящих — самый длинный ключ: проект с
    собственными чатами точнее своего «родителя» по префиксу."""
    best, best_len = None, -1
    m = PM2_CHART.match(chart or "")
    proc = norm(m.group(1)) if m else None
    fm = re.search(r"health\.d/([^,@\s/]+)\.conf", src or "")
    fkey = norm(fm.group(1)) if fm else None
    pm = PROBE_CHART.match(chart or "")
    job = pm.group(2).lower() if pm else None
    for r in routes:
        key = norm(r["name"])
        prefix = r.get("prefix") or key.replace("-", "_")
        if proc is not None:
            ok = proc in {norm(p) for p in r.get("pm2", [])} or _key_match(key, proc)
        else:
            ok = (fkey is not None and _key_match(key, fkey)) \
                or (name or "").startswith(prefix + "_") \
                or (job is not None and (job == prefix or job.startswith(prefix + "_")))
        if ok and len(key) > best_len:
            best, best_len = r, len(key)
    return best


def is_simple(route, name):
    """Аларм простоя: REQUIRED или явный required проекта."""
    return bool(re.search(REQUIRED, name or "")) or (name or "") in set(route.get("required", []))


def _public_url(url):
    """URL пробы показываем, только если он внешний: loopback/частный адрес команде ничего не скажет."""
    try:
        host = urllib.parse.urlsplit(url).hostname or ""
    except ValueError:
        return None
    if not host or host == "localhost":
        return None
    try:
        ip = ipaddress.ip_address(host)
    except ValueError:
        return url
    return None if ip.is_private or ip.is_loopback else url


def _what(route, name, chart, summary, info):
    """(вид, предмет) аларма простоя: ('pm2', 'val-id-api'), ('url', 'https://…'), ('probe', 'порт'), …"""
    m = PM2_CHART.match(chart or "")
    if m or name == "pm2_app_down":
        proc = m.group(1) if m else ""
        if not proc:
            s = re.search(r"pm2_(\S+)", summary or info or "")
            proc = s.group(1) if s else ""
        return "pm2", proc
    if name in ("mysql_down", "clickhouse_down"):
        return name, ""
    p = PROBE_CHART.match(chart or "")
    if p:
        kind, job = p.group(1), p.group(2)
        url = _public_url(route.get("probes", {}).get(job, ""))
        if kind == "httpcheck" and url:
            return "url", url
        return "probe", PROBE_KIND.get(kind, kind)
    text = (summary or info or name or "").strip()
    return "text", text.replace("_", " ") if text == name else text


def cause(route, name, chart, summary="", info=""):
    """Причина простоя человеческими словами, без нод и чартов."""
    kind, what = _what(route, name, chart, summary, info)
    return {
        "pm2": f"процесс {what} не запущен" if what else "процесс не запущен",
        "mysql_down": "база MySQL недоступна",
        "clickhouse_down": "ClickHouse недоступен",
        "url": f"не отвечает {what}",
        "probe": f"не отвечает {what}",
    }.get(kind, what)


def subject(route, name, chart, summary="", info=""):
    """Что проверяет аларм простоя — для /alerts и /status чата проекта."""
    kind, what = _what(route, name, chart, summary, info)
    return {
        "pm2": f"процесс {what}" if what else "процесс",
        "mysql_down": "база MySQL",
        "clickhouse_down": "ClickHouse",
        "url": f"ответ {what}",
        "probe": what,
    }.get(kind, what)
