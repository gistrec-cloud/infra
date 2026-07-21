#!/usr/bin/env bash
# Back up every registered app .env into 1Password (one Document per env
# file), so a dead host never takes app secrets with it. What to back up
# comes from ansible/apps.yml — the registry survives any single host; the
# hosts themselves are only audited for env-looking files that are NOT
# registered (drift = warning + non-zero exit).
#
# Idempotent: re-run after any secret change — items are updated in place,
# keeping item history.
#
# Usage:
#   scripts/backup-envs.sh            # everything in apps.yml
#   scripts/backup-envs.sh russia-01  # only apps on the named host(s)
#   scripts/backup-envs.sh --list     # show the plan, read nothing
#
# Hosts/users/keys come from the gitignored ansible inventory; the app layout
# from the gitignored apps.yml. Nothing secret lives in this script.
set -euo pipefail

VAULT="Gistrec Cloud"
TAG="dotenv-backup"
# germany-02 is not our box (netdata only) — never read files there.
EXCLUDE="germany-02"

cd "$(dirname "$0")/../ansible"
REG="apps.yml"
[ -f "$REG" ] || { echo "FAIL: $REG not found — copy apps.yml.example and fill it in" >&2; exit 1; }

list_only=false
filter=()
for arg in "$@"; do
  case "$arg" in
    --list) list_only=true ;;
    *) filter+=("$arg") ;;
  esac
done
in_filter() {
  [ ${#filter[@]} -eq 0 ] && return 0
  local x; for x in "${filter[@]}"; do [ "$x" = "$1" ] && return 0; done
  return 1
}

# One inventory read for the whole run, with a dummy vault password so ansible
# never invokes .vault_pass (= an `op read` network round-trip — a 1Password
# hiccup would kill the run; nothing in host vars is encrypted). The dummy must
# be non-empty: ansible rejects an empty vault password as invalid.
vpf=$(mktemp)
echo dotenv-backup-dummy > "$vpf"
# Uploads stage through a local scratch file: op reads stdin to EOF and keeps
# whatever arrived, so streaming straight from ssh would turn a dropped
# connection into a truncated "latest" version of the Document.
TMP=$(mktemp)
trap 'rm -f "$vpf" "$TMP"' EXIT
INV=$(ANSIBLE_VAULT_PASSWORD_FILE="$vpf" ansible-inventory --list)

# A typo'd host filter matches nothing and exits 0 — a no-op that looks like
# a fresh backup. Refuse unknown names before any ssh or op side effects.
if [ ${#filter[@]} -gt 0 ]; then
  known=$(python3 -c 'import json,sys
[print(h) for h in json.load(sys.stdin)["_meta"]["hostvars"]]' <<<"$INV")
  for x in "${filter[@]}"; do
    grep -qxF -- "$x" <<<"$known" \
      || { echo "FAIL: unknown host '$x' (known: $(xargs <<<"$known"))" >&2; exit 1; }
  done
fi

# ansible-inventory JSON keeps Jinja UNRENDERED (the key file is
# "~/.ssh/vps-{{ inventory_hostname }}.pub" fleet-wide since 2026-07) —
# template connection vars through ansible itself (debug runs locally).
sshc_host="" sshc_line=""
render_conn() { # <host> — "ip|user|keyfile", cached per host
  if [ "$1" != "$sshc_host" ]; then
    # ansible.cfg defaults callback_result_format=yaml → force json so the sed matches.
    sshc_line=$(ANSIBLE_CALLBACK_RESULT_FORMAT=json ANSIBLE_VAULT_PASSWORD_FILE="$vpf" ansible "$1" -m ansible.builtin.debug \
        -a 'msg={{ ansible_host }}|{{ ansible_user }}|{{ ansible_ssh_private_key_file }}' \
      | sed -n 's/.*"msg": "\(.*\)".*/\1/p')
    sshc_host=$1
  fi
  printf '%s' "$sshc_line"
}

# Registry -> one line per env file: "app<TAB>host<TAB>relative-path"
ENTRIES=$(python3 - "$REG" <<'PY'
import sys, yaml
apps = (yaml.safe_load(open(sys.argv[1])) or {}).get("apps") or {}
for name, a in apps.items():
    d = a.get("dir", ".")
    # env defaults to [.env]; an EXPLICIT `env: []` means "no env files"
    # (static sites and system endpoints).
    for e in (a.get("env") if "env" in a else [".env"]):
        rel = e if d == "." else f"{d}/{e}"
        print(f"{name}\t{a['host']}\t{rel}")
PY
)

# ── one op round-trip for the whole run: title -> item id ──
# `op item get <title>` fails identically for "absent", "ambiguous" and
# "1Password locked"; reading those as "absent" mints duplicate Documents
# (backup-repo-files.sh once made three that way). Refuse to run when op
# is unreachable; the per-title lookups below are then purely local.
if ! $list_only; then
  ITEMS=$(op item list --vault "$VAULT" --format json) || {
    echo "FAIL: op item list failed (1Password locked?) — aborting before any create" >&2
    exit 1
  }
fi
ids_for() { # <title> — matching item ids, one per line
  python3 -c 'import json,sys
[print(i["id"]) for i in json.load(sys.stdin) if i.get("title") == sys.argv[1]]' "$1" <<<"$ITEMS"
}

sshc_for() { # <host> — fills the global sshc array
  local ip user key
  IFS='|' read -r ip user key <<<"$(render_conn "$1")"
  [ -n "$ip" ] && [ -n "$user" ] && [ -n "$key" ] \
    || { echo "FAIL: could not render connection vars for $1" >&2; exit 1; }
  key="${key/#\~/$HOME}"
  # -n: stdin from /dev/null, so ssh calls inside read loops cannot swallow
  # the loop's own input.
  sshc=(ssh -n -o IdentitiesOnly=yes -o ConnectTimeout=15 -i "$key" "$user@$ip")
}

fail=0

# ── Backup pass: exactly what the registry declares ──
while IFS=$'\t' read -r app host rel; do
  [ -n "$app" ] || continue
  in_filter "$host" || continue

  # Item name: the app, plus a suffix when it has several env files
  # (.env.en -> -en, prod.env -> -prod).
  base="${rel##*/}"
  case "$base" in
    .env)   title="dotenv $app" ;;
    .env.*) title="dotenv $app-${base#.env.}" ;;
    *)      title="dotenv $app-${base%.env}" ;;
  esac

  if $list_only; then
    echo "$host: ~/$rel -> \"$title\""
    continue
  fi

  sshc_for "$host"
  if ! want=$("${sshc[@]}" "sha256sum < \"\$HOME/$rel\"" 2>/dev/null | cut -d' ' -f1) || [ -z "$want" ]; then
    echo "FAIL $title — cannot read ~/$rel on $host (file missing / registry drift / SSH failure)" >&2
    fail=1
    continue
  fi

  ids=$(ids_for "$title")
  if [ "$(printf '%s\n' "$ids" | sed '/^$/d' | wc -l | tr -d ' ')" -gt 1 ]; then
    echo "FAIL $title — several 1P items share this title; keep the newest, archive the rest:" >&2
    printf '%s\n' "$ids" | sed 's/^/  op item delete --archive /' >&2
    fail=1
    continue
  fi
  id="$ids" # one item id, or empty when the Document doesn't exist yet

  if ! "${sshc[@]}" "cat \"\$HOME/$rel\"" > "$TMP"; then
    echo "FAIL $title — ssh dropped while downloading ~/$rel from $host" >&2
    fail=1
    continue
  fi
  # $want came from a separate ssh call; a mismatch means a truncated
  # download or a mid-run edit — either way this payload must not reach 1P.
  have=$(shasum -a 256 < "$TMP" | cut -d' ' -f1)
  if [ "$have" != "$want" ]; then
    echo "FAIL $title — ~/$rel changed between hash and download ($have != $want)" >&2
    fail=1
    continue
  fi

  # op reads stdin only from a PIPE — a plain file redirect dies with
  # "expected data on stdin but none found" (op 2.35).
  if [ -n "$id" ]; then
    if ! cat "$TMP" | op document edit "$id" --vault "$VAULT" - >/dev/null; then
      echo "FAIL $title — op document edit failed" >&2
      fail=1
      continue
    fi
    action="updated"
  else
    if ! id=$(cat "$TMP" | op document create - --vault "$VAULT" \
        --title "$title" --file-name "${title#dotenv }.env" --tags "$TAG" \
        --format json | python3 -c 'import json,sys
d=json.load(sys.stdin); print(d.get("uuid") or d.get("id"))'); then
      echo "FAIL $title — op document create failed" >&2
      fail=1
      continue
    fi
    action="created"
  fi

  if ! got=$(op document get "$id" --vault "$VAULT" | shasum -a 256 | cut -d' ' -f1); then
    echo "FAIL $title — cannot read the Document back to verify" >&2
    fail=1
    continue
  fi
  if [ "$want" = "$got" ]; then
    echo "OK   $title ($action, sha256 verified)"
  else
    echo "FAIL $title — hash mismatch after upload" >&2
    fail=1
  fi
done <<<"$ENTRIES"

$list_only && exit 0

# ── Audit pass: env-looking files on the fleet that the registry misses ──
# (single-quoted on purpose — $HOME and the pipeline expand on the remote host)
# shellcheck disable=SC2016
FIND_CMD='
{ pm2 jlist 2>/dev/null | python3 -c "import json,sys; [print(p[\"pm2_env\"][\"pm_cwd\"] + \"/.env\") for p in json.load(sys.stdin)]" 2>/dev/null || true
  find "$HOME" -maxdepth 3 \( -name ".env" -o -name ".env.*" -o -name "*.env" \) \
    -not -name "*.example" -not -name "*.bak" -not -name "*.save" \
    -not -name "*.backup-*" -not -path "*/node_modules/*" 2>/dev/null || true
} | sort -u | while read -r f; do [ -f "$f" ] && echo "$f"; done'

while IFS= read -r host; do
  [ "$host" = "$EXCLUDE" ] && continue
  in_filter "$host" || continue
  regset=$(awk -F'\t' -v h="$host" '$2==h {print $3}' <<<"$ENTRIES")
  sshc_for "$host"
  while IFS= read -r f; do
    [ -n "$f" ] || continue
    rel="${f#/home/*/}"
    if ! grep -qxF "$rel" <<<"$regset"; then
      echo "WARN unregistered env file on $host: ~/$rel — add it to ansible/$REG" >&2
      fail=1
    fi
  done < <("${sshc[@]}" "$FIND_CMD")
done < <(python3 -c 'import json,sys; [print(h) for h in json.load(sys.stdin)["_meta"]["hostvars"]]' <<<"$INV")

exit $fail
