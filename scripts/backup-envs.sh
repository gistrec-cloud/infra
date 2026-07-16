#!/usr/bin/env bash
# Back up every .env on the fleet into 1Password (one Document item per APP —
# secrets belong to the app, not the host), so a dead host never takes app
# secrets with it. Idempotent: re-run after any secret change — items are
# updated in place, keeping item history. If the same app carries different
# .env content on two hosts, the divergent copy is stored as
# "dotenv <app> (<host>)" with a warning: unify it.
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
# One inventory read for the whole run, with a dummy vault password so ansible
# never invokes .vault_pass (= an `op read` network round-trip — a 1Password
# hiccup would kill the run; nothing in host vars is encrypted). The dummy must
# be non-empty: ansible rejects an empty vault password as invalid.
vpf=$(mktemp)
echo dotenv-backup-dummy > "$vpf"
trap 'rm -f "$vpf"' EXIT
INV=$(ANSIBLE_VAULT_PASSWORD_FILE="$vpf" ansible-inventory --list)

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
seen=""   # one line per app already backed up this run: "<app> <sha256> <host>"
for h in "${hosts[@]}"; do
  ip=$(hostvar "$h" ansible_host)
  user=$(hostvar "$h" ansible_user)
  key=$(hostvar "$h" ansible_ssh_private_key_file)
  key="${key/#\~/$HOME}"
  # -n: stdin from /dev/null, so ssh calls inside the while-read loop below
  # cannot swallow the loop's own input (the file list).
  sshc=(ssh -n -o IdentitiesOnly=yes -o ConnectTimeout=15 -i "$key" "$user@$ip")

  while IFS= read -r f; do
    # /home/u/DndCrime/backend/.env -> app "DndCrime-backend"; a bare
    # /home/<user>/.env is named after the user (e.g. vk-ads-tool).
    rel="${f#/home/*/}"
    if [ "$rel" = ".env" ]; then
      app=$(basename "$(dirname "$f")")
    else
      app="${rel%/.env}"
      app="${app//\//-}"
    fi
    title="dotenv $app"

    if $list_only; then
      echo "$h: $f -> \"$title\""
      continue
    fi

    want=$("${sshc[@]}" "sha256sum < '$f'" | cut -d' ' -f1)

    # Same app seen on an earlier host this run?
    prev=$(printf '%s' "$seen" | awk -v a="$app" '$1==a {print $2, $3; exit}')
    if [ -n "$prev" ]; then
      if [ "${prev% *}" = "$want" ]; then
        echo "SKIP $title — $h copy identical to ${prev#* }"
        continue
      fi
      title="dotenv $app ($h)"
      echo "WARN $app: .env on $h differs from ${prev#* } — saved as \"$title\"; unify the app's env" >&2
    else
      seen="${seen}${app} ${want} ${h}"$'\n'
    fi

    if op item get "$title" --vault "$VAULT" >/dev/null 2>&1; then
      "${sshc[@]}" "cat '$f'" | op document edit "$title" --vault "$VAULT" - >/dev/null
      action="updated"
    else
      "${sshc[@]}" "cat '$f'" | op document create - --vault "$VAULT" \
        --title "$title" --file-name "$app.env" --tags "$TAG" >/dev/null
      action="created"
    fi

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
