#!/usr/bin/env python3
"""Move secret values of a local env file into 1Password and leave op:// references behind.

  env-to-op.py PROJECT_DIR [ENV_FILE]           dry run: list keys that would move (names only)
  env-to-op.py PROJECT_DIR [ENV_FILE] --apply   do it

--apply: (1) uploads the original file as a backup document "env <project> <file> backup <date>",
(2) stores secret values as concealed fields of item "env <project> <file>",
(3) checks that `op run --env-file` on the rewritten file resolves to the original values,
(4) only then replaces the file. Non-secret lines and comments are kept verbatim.
Run the app afterwards with:  op run --env-file .env -- <command>
"""
import datetime
import hashlib
import json
import os
import subprocess
import sys
import tempfile

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from envlib import KEY_LINE, is_secret, op, op_json, parse, unquote  # noqa: E402

VAULT = "Gistrec Cloud"


def digest(mapping):
    return hashlib.sha256(json.dumps(mapping, sort_keys=True).encode()).hexdigest()


def main(argv):
    apply = "--apply" in argv
    args = [a for a in argv if not a.startswith("--")]
    if not args:
        sys.exit(__doc__)
    project = os.path.abspath(args[0])
    path = os.path.join(project, args[1] if len(args) > 1 else ".env")
    name = os.path.basename(project)
    fname = os.path.basename(path)
    title = f"env {name} {fname.lstrip('.')}"
    text = open(path, encoding="utf-8").read()
    values = parse(text)
    secrets = {k: v for k, v in values.items() if is_secret(k, v)}
    skipped = []
    for line in text.splitlines():
        m = KEY_LINE.match(line)
        if m and unquote(m.group(3)) is None:
            skipped.append(m.group(2))

    print(f"{path}: {len(values)} keys, {len(secrets)} secret -> '{VAULT}/{title}'")
    print(f"  move: {', '.join(sorted(secrets)) or '-'}")
    print(f"  keep as is: {', '.join(sorted(set(values) - set(secrets))) or '-'}")
    if skipped:
        print(f"  multi-line, left untouched: {', '.join(skipped)}")
    if not apply or not secrets:
        print("  (dry run)" if not apply else "  nothing to do")
        return

    existing = [i for i in op_json("item", "list", "--vault", VAULT) if i["title"] == title]
    if existing:
        sys.exit(f"  item '{title}' already exists in {VAULT}; delete or rename it first")

    stamp = datetime.date.today().isoformat()
    op("document", "create", path, "--vault", VAULT, "--title", f"{title} backup {stamp}", "--file-name", fname)
    print(f"  backup document: '{title} backup {stamp}'")

    template = {
        "title": title,
        "category": "SECURE_NOTE",
        "fields": [{"id": k, "label": k, "type": "CONCEALED", "value": v} for k, v in sorted(secrets.items())],
    }
    op("item", "create", "--vault", VAULT, "--format", "json", stdin=json.dumps(template))
    print(f"  item created: '{title}' ({len(secrets)} fields)")

    out = []
    for line in text.splitlines(keepends=True):
        m = KEY_LINE.match(line.rstrip("\n"))
        if m and m.group(2) in secrets and unquote(m.group(3)) == secrets[m.group(2)]:
            out.append(f"{m.group(1)}{m.group(2)}=op://{VAULT}/{title}/{m.group(2)}\n")
        else:
            out.append(line)
    fd, tmp = tempfile.mkstemp(dir=project, prefix=".env-to-op.")
    with os.fdopen(fd, "w", encoding="utf-8") as f:
        f.writelines(out)
    os.chmod(tmp, 0o600)

    keys = sorted(secrets)
    probe = (
        "import hashlib,json,os,sys;"
        "print(hashlib.sha256(json.dumps({k: os.environ.get(k) for k in sys.argv[1:]}, sort_keys=True).encode()).hexdigest())"
    )
    env = {k: v for k, v in os.environ.items() if k not in secrets}
    res = subprocess.run(
        ["op", "run", "--no-masking", "--env-file", tmp, "--", sys.executable, "-c", probe, *keys],
        capture_output=True, text=True, env=env,
    )
    if res.returncode != 0 or res.stdout.strip() != digest({k: secrets[k] for k in keys}):
        os.remove(tmp)
        sys.exit(f"  VERIFY FAILED, original file kept. {res.stderr.strip()[:300]}")
    os.replace(tmp, path)
    print("  verified: op run resolves every reference to the original value")
    print(f"  {fname} rewritten; run the app with: op run --env-file {fname} -- <command>")


if __name__ == "__main__":
    main(sys.argv[1:])
