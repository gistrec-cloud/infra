#!/usr/bin/env python3
"""Refresh a local copy of a prod env file from its "dotenv <app>" document in 1Password.

  env-pull.py DOC FILE [--keep=K1,K2]

Writes the document to FILE (mode 600). --keep: for these keys the line from the current FILE
wins over the document (local overrides, e.g. a MYSQL_HOST reachable from this machine).
Prints only the key names that changed; never values.
"""
import os
import sys
import tempfile

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from envlib import assignments, op, parse  # noqa: E402

VAULT = "Gistrec Cloud"


def main(argv):
    keep = {k for a in argv if a.startswith("--keep=") for k in a[7:].split(",") if k}
    args = [a for a in argv if not a.startswith("--")]
    if len(args) != 2:
        sys.exit(__doc__)
    doc, path = args
    text = op("document", "get", doc, "--vault", VAULT)
    old_text = open(path, encoding="utf-8").read() if os.path.exists(path) else ""

    old_lines = old_text.splitlines(keepends=True)
    kept = {key: old_lines[i] for i, key, _ in assignments(old_lines) if key in keep}
    if keep - set(kept):
        sys.exit(f"{path}: --keep keys missing from the current file: {', '.join(sorted(keep - set(kept)))}")

    lines = text.splitlines(keepends=True)
    if lines and not lines[-1].endswith("\n"):
        lines[-1] += "\n"
    replaced = set()
    for i, key, _ in assignments(lines):
        if key in kept:
            lines[i] = kept[key] if kept[key].endswith("\n") else kept[key] + "\n"
            replaced.add(key)
    lines += [kept[k] if kept[k].endswith("\n") else kept[k] + "\n" for k in sorted(set(kept) - replaced)]

    old, new = parse(old_text), parse("".join(lines))
    fd, tmp = tempfile.mkstemp(dir=os.path.dirname(os.path.abspath(path)), prefix=".env-pull.")
    with os.fdopen(fd, "w", encoding="utf-8") as f:
        f.writelines(lines)
    os.chmod(tmp, 0o600)
    os.replace(tmp, path)

    print(f"{path} <- '{VAULT}/{doc}': {len(new)} keys")
    for label, keys in (
        ("changed", [k for k in new if k in old and old[k] != new[k]]),
        ("added", [k for k in new if k not in old]),
        ("removed", [k for k in old if k not in new]),
        ("kept local", sorted(kept)),
    ):
        if keys:
            print(f"  {label}: {', '.join(sorted(keys))}")


if __name__ == "__main__":
    main(sys.argv[1:])
