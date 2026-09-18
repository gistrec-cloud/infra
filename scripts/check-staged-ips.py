#!/usr/bin/env python3
"""Не пустить публичный IPv4 в отслеживаемые файлы.

Репозиторий публичный, а часть адресов во флоте чужие: germany-02 мы делим с
посторонним сервисом, и его адрес в git связал бы чужую машину с этой
инфраструктурой. Реальные адреса живут в гитигнорных inventory и host_vars —
хук держит границу, когда рука тянется вписать адрес в коммент или README.

Проверяются только ДОБАВЛЕННЫЕ строки: существующее содержимое не мешает
править соседние места в тех же файлах.

Разрешены приватные и служебные диапазоны плюс всё, что перечислено в
scripts/allowed-public-ips.txt. Обойти разово: git commit --no-verify
"""
import ipaddress
import re
import subprocess
import sys
from pathlib import Path

IPV4 = re.compile(r"(?<![\w.])(?:\d{1,3}\.){3}\d{1,3}(?![\w.])")
ALLOWLIST = Path(__file__).with_name("allowed-public-ips.txt")


def allowed_networks():
    nets = []
    if not ALLOWLIST.exists():
        return nets
    for raw in ALLOWLIST.read_text(encoding="utf-8").splitlines():
        line = raw.split("#", 1)[0].strip()
        if not line:
            continue
        try:
            nets.append(ipaddress.ip_network(line, strict=False))
        except ValueError:
            print(f"check-staged-ips: bad allowlist entry {line!r}", file=sys.stderr)
    return nets


def is_boring(ip):
    """Адреса, которые ничего не раскрывают: приватные, петля, служебные."""
    return (
        ip.is_private
        or ip.is_loopback
        or ip.is_link_local
        or ip.is_multicast
        or ip.is_reserved
        or ip.is_unspecified
        or ip == ipaddress.ip_address("255.255.255.255")
    )


def staged_additions():
    """(файл, номер строки, текст) для каждой добавленной строки индекса."""
    diff = subprocess.run(
        ["git", "diff", "--cached", "-U0", "--diff-filter=ACM"],
        capture_output=True, text=True, check=True,
    ).stdout
    path, lineno = None, 0
    for line in diff.splitlines():
        if line.startswith("+++ b/"):
            path = line[6:]
        elif line.startswith("@@"):
            # @@ -a,b +c,d @@ — счётчик ведём по новой стороне.
            m = re.search(r"\+(\d+)", line)
            lineno = int(m.group(1)) if m else 0
        elif line.startswith("+") and not line.startswith("+++"):
            yield path, lineno, line[1:]
            lineno += 1


def main():
    nets = allowed_networks()
    violations = []
    for path, lineno, text in staged_additions():
        for literal in IPV4.findall(text):
            try:
                ip = ipaddress.ip_address(literal)
            except ValueError:
                continue  # 999.1.1.1 и прочее — не адрес
            if is_boring(ip) or any(ip in n for n in nets):
                continue
            violations.append((path, lineno, literal, text.strip()))

    if not violations:
        return 0

    print("\nПубличный IPv4 в отслеживаемых файлах — коммит остановлен.\n")
    for path, lineno, literal, text in violations:
        snippet = text if len(text) <= 100 else text[:97] + "..."
        print(f"  {path}:{lineno}: {literal}")
        print(f"      {snippet}")
    print(
        "\nАдреса флота живут в гитигнорных ansible/inventory и host_vars.\n"
        "Если адрес правда публичный и безобидный (диапазон CDN, пример из RFC) —\n"
        f"впишите его в {ALLOWLIST.name} с комментарием, зачем.\n"
        "Разовый обход: git commit --no-verify\n"
    )
    return 1


if __name__ == "__main__":
    sys.exit(main())
