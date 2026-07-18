#!/usr/bin/env bash
# Back up the repo's gitignored LIVE DATA into 1Password as one tar.gz
# Document — the "code is public, live data is gitignored" rule means the
# inventory, registry, vault, vhosts and terraform state/vars exist only
# on this laptop; a dead laptop must not take them with it.
#
# One Document ("infra repo-private files", tag repo-backup) holding a
# whitelisted archive; 1Password keeps version history on every update.
# A manifest of per-file sha256 rides inside the archive — when nothing
# changed since the last upload, the run is a no-op (no junk versions).
#
# Restore on a fresh machine (from the repo root, after git clone):
#   op document get "infra repo-private files" --vault "Gistrec Cloud" \
#     | tar xzf - -C .
#
# Usage:
#   scripts/backup-repo-files.sh          # back up + verify
#   scripts/backup-repo-files.sh --list   # show what would go up
#
# Re-run after changing any of: inventory/host_vars, apps.yml, the vault,
# vhosts, control scripts, terraform tfvars — and after EVERY terraform
# apply (the state files are in here until they move to a remote backend).
set -euo pipefail

VAULT="Gistrec Cloud"
TITLE="infra repo-private files"
TAG="repo-backup"
MANIFEST=".backup-manifest.sha256"

cd "$(dirname "$0")/.."

# ── whitelist ──
# Required singletons fail loud when missing; globbed groups may legally
# be empty one by one, but a run that collects nothing is refused.
collect() {
  ls ansible/inventory/hosts.yml
  ls ansible/apps.yml
  ls ansible/group_vars/*.vault.yml
  ls ansible/.vault_pass
  ls .envrc
  ls ansible/host_vars/*.yml 2>/dev/null || true
  ls ansible/files/vhosts/*.conf 2>/dev/null || true
  find ansible/files/bin -type f ! -name "*.example" 2>/dev/null || true
  ls terraform/*/terraform.tfvars 2>/dev/null || true
  ls terraform/*/terraform.tfstate 2>/dev/null || true
}

FILES=$(collect)
[ -n "$FILES" ] || { echo "FAIL: nothing to back up?" >&2; exit 1; }

if [ "${1:-}" = "--list" ]; then
  echo "$FILES"
  exit 0
fi

# Tracked files in the whitelist mean the globs caught something public —
# refuse instead of quietly archiving what git already keeps.
# shellcheck disable=SC2086  # word-splitting the file list is intended
tracked=$(git ls-files -- $FILES)
if [ -n "$tracked" ]; then
  echo "FAIL: whitelist matched TRACKED files (already safe in git):" >&2
  echo "$tracked" >&2
  exit 1
fi

# ── resolve the 1P item up front, refusing to guess ──
# `op item get <title>` fails identically for "absent", "ambiguous" and
# "1Password locked", and reading those as "absent" is how this script
# once minted three duplicate Documents (2026-07-18). Enumerate instead:
# abort unless op answers and the title matches at most one item.
ITEMS=$(op item list --vault "$VAULT" --format json) || {
  echo "FAIL: op item list failed (1Password locked?) — aborting before any create" >&2
  exit 1
}
IDS=$(python3 -c 'import json,sys
[print(i["id"]) for i in json.load(sys.stdin) if i.get("title") == sys.argv[1]]' "$TITLE" <<<"$ITEMS")
if [ "$(printf '%s\n' "$IDS" | sed '/^$/d' | wc -l | tr -d ' ')" -gt 1 ]; then
  echo "FAIL: several items share the title \"$TITLE\" — keep the newest, archive the rest:" >&2
  printf '%s\n' "$IDS" | sed 's/^/  op item delete --archive /' >&2
  exit 1
fi
ID="$IDS" # one item id, or empty when the Document doesn't exist yet

tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT

echo "$FILES" | xargs shasum -a 256 | sort -k2 > "$tmp/$MANIFEST"

# Skip the upload when the last backed-up manifest is identical.
if [ -n "$ID" ] \
   && op document get "$ID" --vault "$VAULT" 2>/dev/null \
     | tar xzqf - -O "$MANIFEST" > "$tmp/prev" 2>/dev/null \
   && cmp -s "$tmp/$MANIFEST" "$tmp/prev"; then
  echo "OK   $TITLE (unchanged since the last backup — nothing uploaded)"
  exit 0
fi

cp "$tmp/$MANIFEST" "$MANIFEST"
# shellcheck disable=SC2086  # word-splitting the file list is intended
tar czf "$tmp/backup.tar.gz" "$MANIFEST" $FILES
rm -f "$MANIFEST"

# op reads stdin only from a PIPE — a plain file redirect dies with
# "expected data on stdin but none found" (op 2.35).
if [ -n "$ID" ]; then
  cat "$tmp/backup.tar.gz" | op document edit "$ID" --vault "$VAULT" - >/dev/null
  action="updated"
else
  ID=$(cat "$tmp/backup.tar.gz" | op document create - --vault "$VAULT" \
    --title "$TITLE" --file-name "infra-repo-private.tar.gz" --tags "$TAG" \
    --format json | python3 -c 'import json,sys
d=json.load(sys.stdin); print(d.get("uuid") or d.get("id"))')
  action="created"
fi

want=$(shasum -a 256 < "$tmp/backup.tar.gz" | cut -d' ' -f1)
got=$(op document get "$ID" --vault "$VAULT" | shasum -a 256 | cut -d' ' -f1)
if [ "$want" = "$got" ]; then
  echo "OK   $TITLE ($action, $(echo "$FILES" | wc -l | tr -d ' ') files, sha256 verified)"
else
  echo "FAIL $TITLE — hash mismatch after upload" >&2
  exit 1
fi
