"""Shared helpers for env-compare.py and env-to-op.py. Never prints values."""
import json
import re
import subprocess

KEY_LINE = re.compile(r"^(\s*(?:export\s+)?)([A-Za-z_][A-Za-z0-9_]*)\s*=\s*(.*)$")
COMMENTED = re.compile(r"^\s*#+\s*(?:export\s+)?([A-Za-z_][A-Za-z0-9_]*)\s*=\s*(.*)$")
# Whole words of the key name (split on "_"): MAX_OUTPUT_TOKENS, ENABLE_SECURE_COOKIES and
# YANDEX_OAUTH_CLIENT_ID are settings, TELEGRAM_API_HASH and TOKEN_ENCRYPTION_KEY are secrets.
SECRET_WORDS = {
    "PASS", "PASSWD", "PASSWORD", "PWD", "SECRET", "TOKEN", "KEY", "APIKEY", "DSN",
    "HASH", "PRIVATE", "CREDENTIAL", "CREDENTIALS", "SALT", "WEBHOOK", "SIGNING",
}
URL_WITH_PASSWORD = re.compile(r"://[^/@\s:]+:[^/@\s]+@")


def unquote(raw):
    """Value of a single-line dotenv assignment, or None if it is multi-line or malformed."""
    raw = raw.strip()
    if raw[:1] in ("'", '"'):
        quote = raw[0]
        end = raw.find(quote, 1)
        while end != -1 and quote == '"' and raw[end - 1] == "\\":
            end = raw.find(quote, end + 1)
        if end == -1:
            return None  # opening quote without a closing one: multi-line value
        return raw[1:end]
    return re.split(r"\s+#", raw, maxsplit=1)[0].strip()


def parse(text):
    """{key: value} for every single-line assignment; later keys win, like dotenv."""
    out = {}
    for line in text.splitlines():
        m = KEY_LINE.match(line)
        if m:
            value = unquote(m.group(3))
            if value is not None:
                out[m.group(2)] = value
    return out


def is_secret(key, value, also=(), keep=()):
    if not value or value.startswith("op://") or key in keep:
        return False
    words = set(key.upper().split("_"))
    return bool(key in also or words & SECRET_WORDS or URL_WITH_PASSWORD.search(value))


def op(*args, stdin=None):
    res = subprocess.run(["op", *args], input=stdin, capture_output=True, text=True)
    if res.returncode != 0:
        raise RuntimeError(f"op {args[0]} {args[1] if len(args) > 1 else ''} failed: {res.stderr.strip()[:300]}")
    return res.stdout


def op_json(*args):
    return json.loads(op(*args, "--format", "json"))
