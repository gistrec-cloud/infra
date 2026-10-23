#!/usr/bin/env python3
"""Снимок статус-страницы: раз в минуту (status-snapshot.timer) собирает из API
netdata-парента проекты, их алерты, историю аптайма и время рестартов и пишет два
файла — полный для приватной stats.gistrec.cloud/status и урезанный для
публичной gistrec.cloud/status (без нод, алертов и ссылок).

Конфиг — /etc/status-snapshot.json (роль netdata, netdata_status_*)."""
import json
import os
import re
import sys
import tempfile
import time
import urllib.parse
import urllib.request
from concurrent.futures import ThreadPoolExecutor

CONFIG = sys.argv[1] if len(sys.argv) > 1 else '/etc/status-snapshot.json'
API = 'http://127.0.0.1:19999'

RANK = {'CRITICAL': 3, 'WARNING': 2, 'UNDEFINED': 1, 'UNINITIALIZED': 1, 'CLEAR': 0}
CLS = {'CRITICAL': 'crit', 'WARNING': 'warn', 'UNDEFINED': 'nodata', 'UNINITIALIZED': 'nodata', 'CLEAR': 'ok'}
STALE_SEC = 3600  # алерты снятых с парка нод застывают — отбрасываем
RANGES = {'24h': (86400, 48), '7d': (604800, 42)}
DAY = 86400
OK_FROM = 0.999  # отрезок не ниже — зелёный, как bucket() на страницах

# Инфраструктура — строки по подсистемам. ping.conf = fleet-link/fleet-uplink
# под стоковым именем; host_clock_* из trade_lab_clock.conf висит на каждой ноде
INFRA_FILES = [
    (r'^mysql$', 'MySQL'), (r'^clickhouse-down$', 'ClickHouse'),
    (r'^(backup-staleness|s3-mirror)$', 'S3 Backups'),
    (r'^tg-bot-api$', 'Telegram Bot API'), (r'^lambda-relay$', 'AWS Relays'),
    (r'^(ping|portcheck-down)$', 'Network'), (r'^(fleet-|disk-space-early|oom-notify)', 'VPS'),
]
INFRA_CHARTS = [(r'^mysql_', 'MySQL'), (r'^clickhouse_', 'ClickHouse'),
                (r'^x509check_', 'TLS'), (r'^portcheck_k3s_', 'k3s')]
INFRA_ROWS = {'MySQL', 'ClickHouse', 'S3 Backups', 'Telegram Bot API', 'AWS Relays', 'k3s', 'Network', 'VPS', 'TLS'}
STOCK_ROW = 'VPS'  # горящие стоковые алерты netdata
ALIASES = {'vkadstool': 'vk-ads-tool', 'dnd-crime-api': 'dnd-crime'}

# Публичная подпись пробы: в именах этих джоб — ноды, а ноды наружу не отдаём
PUBLIC_PROBES = [(r'^watch_xray_', 'proxy port'), (r'^(health|watch)_', 'host health'),
                 (r'^(link|uplink)_', 'network link'), (r'^k3s_', 'k3s API')]
PROBE_KIND = {'httpcheck': 'health check', 'portcheck': 'port', 'ping': 'network link', 'filecheck': 'freshness',
              'x509check': 'TLS cert', 'mysql': 'MySQL', 'clickhouse': 'ClickHouse', 'pm2': 'process'}


def get(path):
    with urllib.request.urlopen(API + path, timeout=20) as r:
        return json.load(r)


def base(host, parent):
    return '' if host == parent else '/host/' + urllib.parse.quote(host)


def project_of(a):
    for rx, row in INFRA_CHARTS:
        if re.search(rx, a['chart']):
            return row
    m = re.search(r'file=/etc/netdata/health\.d/([^,]+)\.conf', a.get('source') or '')
    if not m:
        return None
    key = m.group(1).lower().replace('_', '-')
    for rx, row in INFRA_FILES:
        if re.search(rx, key):
            return row
    if a['name'].startswith('host_clock_'):
        return 'VPS'
    if key in ('pm2', 'pm2-memory'):
        c = re.match(r'^app\.pm2_(.+)_(processes|mem_usage)$', a['chart'])
        if not c:
            return None
        key = c.group(1).lower().replace('_', '-')
    return ALIASES.get(key, key)


def merge_prefixes(groups):
    """trade-lab-clock, askads-cloud, dnd-crime-api-staging → к самому короткому префиксу."""
    for k in sorted(groups, key=len):
        if k not in groups:
            continue
        root = next((r for r in sorted(groups, key=len) if r != k and k.startswith(r + '-')), None)
        if root:
            groups[root].extend(groups.pop(k))


def fresh_ok(warn_h, crit_h):
    return lambda v: 1 if v < warn_h * 3600 else 0.96 if v < crit_h * 3600 else 0


def probes(alarms):
    """Пробы истории: значение отрезка 1 = норма, 0.95–0.999 = warn, ниже = crit.
    Если проб нет — живость pm2-процесса."""
    out, pm2 = {}, {}

    def add(a, chart, dim, group, fn=lambda v: v, gap_down=False):
        # «from»: хост — откуда данные; у http/port/ping это проверяющий, не место приложения
        out[a['host'] + chart] = dict(host=a['host'], chart=chart, dim=dim, group=group, fn=fn, gap_down=gap_down,
                                      label=f"{chart.split('.')[0]} from {a['host']}")

    for a in alarms:
        c = a['chart']
        if re.match(r'^httpcheck_.+\.request_status$', c) or re.match(r'^portcheck_.+_status$', c):
            add(a, c, 'success', 'average')
        elif re.match(r'^ping_.+\.host_packet_loss_', c):
            add(a, c, 'loss', 'average', lambda v: 1 - v / 100)
        # у БД пропуск сбора после начала мониторинга = сервер не отвечал
        elif m := re.match(r'^mysql_([^.]+)\.', c):
            add(a, f'mysql_{m[1]}.queries', 'queries', 'average', lambda v: 1, True)
        elif m := re.match(r'^clickhouse_([^.]+)\.', c):
            add(a, f'clickhouse_{m[1]}.uptime', 'uptime', 'average', lambda v: 1, True)
        elif m := re.match(r'^filecheck_(.+_backup|s3_mirror|glucose)\..+modification_time_ago$', c):
            # пороги (warn, crit в часах) как в алертах: бэкапы суточные, зеркало раз в 6 ч
            warn_h, crit_h = {'s3_mirror': (13, 25), 'glucose': (0.5, 1)}.get(m[1], (30, 50))
            add(a, c, 'mtime_ago', 'max', fresh_ok(warn_h, crit_h))
        elif m := re.match(r'^(x509check_[^.]+)\.', c):
            add(a, m[1] + '.cert_depth0_time_until_expiration', 'expiry', 'min',
                lambda v: 1 if v > 14 * DAY else 0.96 if v > 7 * DAY else 0)
        if m := re.match(r'^app\.pm2_(.+)_processes$', c):
            pm2[a['host'] + m[1]] = dict(host=a['host'], app=m[1], label=f"pm2 {m[1]} from {a['host']}")
    return list(out.values()), list(pm2.values())


def series(parent, host, chart, dim, group, rng):
    after, points = RANGES[rng]
    q = urllib.parse.urlencode(dict(chart=chart, after=-after, points=points, group=group,
                                    format='json', dimensions=dim))
    rows = list(reversed(get(f'{base(host, parent)}/api/v1/data?{q}')['data']))
    v = ([None] * max(0, points - len(rows)) + [r[1] for r in rows])[-points:]
    return v, [r[0] for r in rows]


def history(parent, alarms, rng):
    _, points = RANGES[rng]
    plist, pm2 = probes(alarms)
    rows, labels, t = [], [], None
    for s in plist:
        try:
            v, ts = series(parent, s['host'], s['chart'], s['dim'], s['group'], rng)
        except Exception:
            continue  # проба, чарта которой ещё нет, не валит остальные
        first = next((i for i, x in enumerate(v) if x is not None), None)
        rows.append([s['fn'](x) if x is not None else 0 if s['gap_down'] and first is not None and i > first else None
                     for i, x in enumerate(v)])
        labels.append(s['label'])
        if len(ts) == points:
            t = ts
    if not plist:
        for s in pm2:
            try:
                v, ts = series(parent, s['host'], f"app.pm2_{s['app']}_processes", 'processes', 'min', rng)
            except Exception:
                continue
            rows.append([None if x is None else 1 if x > 0 else 0 for x in v])
            labels.append(s['label'])
            if len(ts) == points:
                t = ts
    if not rows:
        return None
    merged, bad = [], []
    for i in range(points):
        vals = sorted((r[i], k) for k, r in enumerate(rows) if r[i] is not None)
        merged.append(vals[0][0] if vals else None)  # худшая из проб в отрезке
        # все пробы ниже нормы, худшая первой: [индекс в labels, значение]
        bad.append([[k, round(x, 4)] for x, k in vals if x < OK_FROM] or None)
    known = [x for x in merged if x is not None]
    return dict(v=[None if x is None else round(x, 4) for x in merged], t=t, w=bad, labels=labels,
                uptime=round(sum(known) / len(known) * 100, 2) if known else None)


def restart(parent, alarms):
    ups = []
    for a in alarms:
        if m := re.match(r'^app\.pm2_(.+)_processes$', a['chart']):
            try:
                d = get(f"{base(a['host'], parent)}/api/v1/data?chart=app.pm2_{urllib.parse.quote(m[1])}_uptime"
                        '&after=-60&points=1&format=json')
                if d['data'] and d['data'][0][1] is not None:
                    ups.append(d['data'][0][1])
            except Exception:
                pass
    return min(ups) if ups else None


def build(cfg):
    parent = cfg['parent']
    prod, hosts_map = set(cfg['prod']), cfg['hosts']
    hosts = get('/api/v1/info').get('mirrored_hosts') or [parent]
    now = time.time()
    groups, failed = {}, []
    for h in hosts:
        try:
            alarms = get(f'{base(h, parent)}/api/v1/alarms?all')['alarms'].values()
        except Exception:
            failed.append(h)
            continue
        for a in alarms:
            if now - a['last_updated'] > STALE_SEC:
                continue
            a = dict(a, host=h)
            p = project_of(a)
            # стоковые алерты netdata показываются, только когда горят, — в строке VPS
            if not p and RANK[a['status']] >= 2:
                p, a['stock'] = STOCK_ROW, True
            if p:
                groups.setdefault(p, []).append(a)
    merge_prefixes(groups)

    def one(item):
        name, alarms = item
        alarms.sort(key=lambda a: (-RANK[a['status']], a['name']))
        kind = 'infra' if name in INFRA_ROWS else 'prod' if name in prod else 'pet'
        pm2_hosts = sorted({a['host'] for a in alarms if a['chart'].startswith('app.pm2_')})
        return dict(
            name=name, kind=kind, worst=alarms[0]['status'],
            hosts=hosts_map.get(name) or pm2_hosts or sorted({a['host'] for a in alarms}),
            link_host=alarms[0]['host'], sentry=cfg['sentry'].get(name),
            restart=restart(parent, alarms),
            history={rng: history(parent, alarms, rng) for rng in RANGES},
            alarms=[dict(name=a['name'], status=a['status'], value=a.get('value_string'),
                         info=a.get('summary') or a.get('info'), host=a['host'],
                         since=a.get('last_status_change'), stock=a.get('stock', False))
                    for a in alarms],
        )

    with ThreadPoolExecutor(8) as ex:
        projects = list(ex.map(one, groups.items()))
    projects.sort(key=lambda p: (-RANK[p['worst']], p['name']))
    return dict(generated_at=int(now), parent=parent, nodes=hosts, failed=failed,
                summary=summary(projects), projects=projects)


def summary(projects):
    """Плашки считают все горящие алерты; заголовок — без warning пет-проектов и стоковых."""
    hot = [(p, a) for p in projects for a in p['alarms'] if RANK[a['status']] >= 2]
    serious = [a for p, a in hot if not (a['status'] == 'WARNING' and (a['stock'] or p['kind'] == 'pet'))]
    return dict(total=sum(len(p['alarms']) for p in projects),
                crit=sum(a['status'] == 'CRITICAL' for _, a in hot),
                warn=sum(a['status'] == 'WARNING' for _, a in hot),
                verdict_crit=sum(a['status'] == 'CRITICAL' for a in serious),
                verdict_warn=sum(a['status'] == 'WARNING' for a in serious))


def public_label(label, project):
    """«httpcheck_edalle_foodops_testing from russia-03» → «testing»: без ноды и префикса проекта."""
    m = re.match(r'^(?:pm2 \S+|([a-z0-9]+?)_(\S+?)) from ', label)
    if not m or not m[1]:
        return PROBE_KIND['pm2']
    kind, job = m[1], m[2]
    for rx, text in PUBLIC_PROBES:
        if re.match(rx, job):
            return text
    if kind == 'x509check':
        return re.sub(r'_([a-z]+)$', r'.\1', job).replace('_', '-')
    if job == 'local':
        return PROBE_KIND.get(kind, kind)
    for key in {project, 'tg-bot-api', *(k for k, v in ALIASES.items() if v == project)}:
        key = key.lower().replace('-', '_')
        if key.replace('_', '').startswith(job.replace('_', '')):  # cleartranscript ↔ clear-transcript-bot
            return PROBE_KIND.get(kind, kind)
        if job.startswith(key + '_'):
            job = job[len(key) + 1:]
            break
    return job.replace('_', ' ')


def public(snap):
    """Наружу — только имена, статусы, история и рестарты: без нод, алертов и ссылок.
    Подписи проб в истории — короткие (public_label)."""
    def hist(h, name):
        """Короткие подписи; пробы, слившиеся в одну («network link»), — одной строкой с худшим значением."""
        if not h:
            return h
        short = [public_label(x, name) for x in h['labels']]
        labels = list(dict.fromkeys(short))
        w = []
        for bad in h['w']:
            seen, out = set(), []
            for k, v in bad or []:  # худшая первой — первое вхождение метки и есть худшее
                if short[k] not in seen:
                    seen.add(short[k])
                    out.append([labels.index(short[k]), v])
            w.append(out or None)
        return dict(h, labels=labels, w=w)

    def strip(p):
        hot = any(RANK[a['status']] >= 2 for a in p['alarms'])
        dot = CLS[p['worst']] if hot else 'nodata' if all(RANK[a['status']] == 1 for a in p['alarms']) else 'ok'
        return dict(name=p['name'], kind=p['kind'], dot=dot, restart=p['restart'],
                    history={rng: hist(h, p['name']) for rng, h in p['history'].items()})
    return dict(generated_at=snap['generated_at'], public=True, summary=snap['summary'],
                projects=[strip(p) for p in snap['projects']])


def write(path, data):
    d = os.path.dirname(path)
    fd, tmp = tempfile.mkstemp(dir=d, prefix='.status-')
    with os.fdopen(fd, 'w') as f:
        json.dump(data, f, ensure_ascii=False, separators=(',', ':'))
    os.chmod(tmp, 0o644)
    os.replace(tmp, path)  # атомарно: страница не прочтёт полуфайл


def main():
    with open(CONFIG) as f:
        cfg = json.load(f)
    snap = build(cfg)
    write(cfg['private_out'], snap)
    if cfg.get('public_out'):
        write(cfg['public_out'], public(snap))


if __name__ == '__main__':
    main()
