#!/usr/bin/env bash
# Back up every .env on the fleet into 1Password (one Document item per file),
# so a dead host never takes app secrets with it. Idempotent: re-run after any
# secret change — existing items are updated in place, keeping item history.
#
# Usage:
#   scripts/backup-envs.sh            # every fleet host from the ansible inventory
#   scripts/backup-envs.sh russia-01  # only the named host(s)
#   scripts/backup-envs.sh --list     # show what would be backed up, read nothing
#
# Hosts, users and SSH keys come from the gitignored ansible inventory; nothing
# secret lives in this script. Requires: op (signed in), ansible, ssh.
set -euo pipefail

VAULT="Gistrec Cloud"
TAG="dotenv-backup"
# germany-02 is not our box (netdata only) — never read files there.
EXCLUDE="germany-02"

cd "$(dirname "$0")/../ansible"

list_only=false
hosts=()
for arg in "$@"; do
  case "$arg" in
    --list) list_only=true ;;
    *) hosts+=("$arg") ;;
  esac
done
# One inventory read for the whole run. The empty vault password keeps ansible
# from invoking .vault_pass (= an `op read` network round-trip per call — a
# single 1Password hiccup would kill the run; nothing in host vars is encrypted).
INV=$(ANSIBLE_VAULT_PASSWORD_FILE=/dev/null ansible-inventory --list 2>/dev/null)

if [ ${#hosts[@]} -eq 0 ]; then
  while IFS= read -r h; do
    [ "$h" = "$EXCLUDE" ] || hosts+=("$h")
  done < <(python3 -c \
    'import json,sys; [print(h) for h in json.load(sys.stdin)["_meta"]["hostvars"]]' <<<"$INV")
fi

hostvar() {
  python3 -c 'import json,sys; print(json.load(sys.stdin)["_meta"]["hostvars"][sys.argv[1]].get(sys.argv[2],""))' \
    "$1" "$2" <<<"$INV"
}

# .env candidates: pm2 app working dirs plus a shallow sweep of $HOME
# (single-quoted on purpose — $HOME and the pipeline expand on the remote host).
# shellcheck disable=SC2016
FIND_CMD='
{ pm2 jlist 2>/dev/null | python3 -c "import json,sys; [print(p[\"pm2_env\"][\"pm_cwd\"] + \"/.env\") for p in json.load(sys.stdin)]" 2>/dev/null || true
  find "$HOME" -maxdepth 3 -name ".env" 2>/dev/null || true
} | sort -u | while read -r f; do [ -f "$f" ] && echo "$f"; done'

fail=0
for h in "${hosts[@]}"; do
  ip=$(hostvar "$h" ansible_host)
  user=$(hostvar "$h" ansible_user)
  key=$(hostvar "$h" ansible_ssh_private_key_file)
  key="${key/#\~/$HOME}"
  # -n: stdin from /dev/null, so ssh calls inside the while-read loop below
  # cannot swallow the loop's own input (the file list).
  sshc=(ssh -n -o IdentitiesOnly=yes -o ConnectTimeout=15 -i "$key" "$user@$ip")

  while IFS= read -r f; do
    # /home/u/DndCrime/backend/.env -> item "dotenv <host> DndCrime-backend"
    rel="${f#/home/*/}"
    rel="${rel%/.env}"
    rel="${rel//\//-}"
    [ "$rel" = ".env" ] && rel="home"   # .env sitting directly in $HOME
    title="dotenv $h $rel"

    if $list_only; then
      echo "$h: $f -> \"$title\""
      continue
    fi

    if op item get "$title" --vault "$VAULT" >/dev/null 2>&1; then
      "${sshc[@]}" "cat '$f'" | op document edit "$title" --vault "$VAULT" - >/dev/null
      action="updated"
    else
      "${sshc[@]}" "cat '$f'" | op document create - --vault "$VAULT" \
        --title "$title" --file-name "$rel.env" --tags "$TAG" >/dev/null
      action="created"
    fi

    want=$("${sshc[@]}" "sha256sum < '$f'" | cut -d' ' -f1)
    got=$(op document get "$title" --vault "$VAULT" | shasum -a 256 | cut -d' ' -f1)
    if [ "$want" = "$got" ]; then
      echo "OK   $title ($action, sha256 verified)"
    else
      echo "FAIL $title — hash mismatch after upload" >&2
      fail=1
    fi
  done < <("${sshc[@]}" "$FIND_CMD")
done
exit $fail
