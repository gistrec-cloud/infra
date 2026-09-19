#!/usr/bin/env python3
"""Проверить, что заданные подсети не пересекаются с маршрутами хоста.

Подстроковое сравнение тут не годится в обе стороны: маршрут 10.0.0.0/8
содержит и 10.42/16, и 10.43/16, но строки «10.42.» в нём нет — а именно
такой маршрут и бывает у чужого VPN, ради которого проверка затевалась.
Обратный промах тоже реален: адрес вида 110.42.0.1 содержит «10.42.» и
заблокировал бы установку на свободной подсети.

Выход 0 — чисто, 2 — пересечение (и причина в stderr).
"""
import ipaddress
import subprocess
import sys


def host_networks():
    out = subprocess.run(
        ["ip", "-4", "route", "show", "table", "all"],
        capture_output=True, text=True, check=True,
    ).stdout
    for line in out.splitlines():
        for token in line.split():
            # Первый разбираемый токен строки — её назначение; дальше идут
            # via/dev/src, которые сетями не являются.
            try:
                yield ipaddress.ip_network(token, strict=False)
            except ValueError:
                continue
            break


def main(argv):
    if not argv:
        print("usage: check-cidr-overlap.py CIDR [CIDR ...]", file=sys.stderr)
        return 2
    existing = list(host_networks())
    clashes = []
    for raw in argv:
        want = ipaddress.ip_network(raw, strict=False)
        for have in existing:
            if want.overlaps(have):
                clashes.append((want, have))
    if clashes:
        for want, have in clashes:
            print(f"{want} overlaps the existing route {have}", file=sys.stderr)
        return 2
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
