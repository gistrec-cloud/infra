#!/usr/bin/env python3
"""Добавленные строки индекса — общая часть проверок pre-commit.

Проверяются только ДОБАВЛЕННЫЕ строки: существующее содержимое не мешает
править соседние места в тех же файлах.
"""
import re
import subprocess


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
