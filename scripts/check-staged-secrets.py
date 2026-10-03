#!/usr/bin/env python3
"""Не пустить ключ-строку в отслеживаемые файлы.

gitleaks ловит секреты по форме токенов известных сервисов, а uuid клиента и
base64-ключ кривой на них не похожи — хотя uuid и есть пароль к inbound, а
приватный x25519 открывает его целиком. Значения живут в гитигнорных host_vars
и в vault; хук держит границу, когда рука тянется вписать их «на один прогон».

Короткие hex-строки (shortId) сознательно не ловятся: от короткого git-хеша их
не отличить, а без uuid и ключа они сами по себе ничего не открывают.

Разрешить строку — комментарий `allow-secret` в ней же; разовый обход —
git commit --no-verify
"""
import re
import sys

from staged_diff import staged_additions

# Лукэраунды с обеих сторон: без них 43 символа нашлись бы внутри любого
# длинного base64-блока, а искать надо ровно ключ целиком.
B64URL = r"(?<![A-Za-z0-9_=-])[A-Za-z0-9_-]{43}(?![A-Za-z0-9_=-])"
B64STD = r"(?<![A-Za-z0-9+/=])[A-Za-z0-9+/]{43}=(?![A-Za-z0-9+/=])"

PATTERNS = [
    ("uuid", re.compile(r"(?<![0-9a-f])[0-9a-f]{8}(?:-[0-9a-f]{4}){3}-[0-9a-f]{12}(?![0-9a-f])", re.I)),
    ("ключ x25519/base64", re.compile(f"{B64URL}|{B64STD}")),
]

# Ключевой материал в .pem уже закрыт хуком detect-private-key, а строки
# сертификатов дают ложные срабатывания на подходящей длине.
SKIP_SUFFIXES = (".pem",)


def main():
    violations = []
    for path, lineno, text in staged_additions():
        if path is None or path.endswith(SKIP_SUFFIXES):
            continue
        if "allow-secret" in text:
            continue
        for label, pattern in PATTERNS:
            for literal in pattern.findall(text):
                violations.append((path, lineno, label, literal))

    if not violations:
        return 0

    print("\nКлюч-строка в отслеживаемых файлах — коммит остановлен.\n")
    for path, lineno, label, literal in violations:
        shown = literal if len(literal) <= 12 else literal[:6] + "…" + literal[-4:]
        print(f"  {path}:{lineno}: {label} {shown}")
    print(
        "\nuuid клиентов и ключи живут в гитигнорных host_vars и в vault —\n"
        "в код попадают только имена переменных.\n"
        "Если строка правда не секрет (пример в документации, тестовый вектор) —\n"
        "допишите в неё комментарий allow-secret.\n"
        "Разовый обход: git commit --no-verify\n"
    )
    return 1


if __name__ == "__main__":
    sys.exit(main())
