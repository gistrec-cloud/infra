#!/usr/bin/env bash
# Back up trade-lab's local runtime data into 1Password, so a dead host never
# takes the trading journal with it. Companion to backup-envs.sh (same
# registry, same vault, same verify-after-upload discipline).
#
# What goes up:
#   data/journal/cycles.jsonl          -> "data trade-lab-cycles"          (thinned)
#   data/journal/cycles_mainnet.jsonl  -> "data trade-lab-cycles-mainnet"  (as is)
#   data/state/orders.json             -> "data trade-lab-orders"          (as is)
#
# Thinning: until 2026-07-08 the testnet cycle ran HOURLY; since then the
# schedule is every 6 hours (00/06/12/18 UTC — the host runs Etc/UTC). The
# hourly-era extras carry no signal worth keeping, so only records whose
# started_at hour sits on the 6-hour grid are backed up. Current-era records
# all pass by construction; the on-host journal itself is never modified.
#
# Idempotent: re-run any time — items are updated in place, keeping history.
#
# Usage:
#   scripts/backup-trade-lab.sh          # back up + verify
#   scripts/backup-trade-lab.sh --list   # show the plan, read nothing
set -euo pipefail

VAULT="Gistrec Cloud"
TAG="data-backup"
APP="trade-lab"

cd "$(dirname "$0")/../ansible"
REG="apps.yml"
[ -f "$REG" ] || { echo "FAIL: $REG not found — copy apps.yml.example and fill it in" >&2; exit 1; }

# rel-path <TAB> 1P item title <TAB> thin? (journal grows, state is tiny)
FILES=$'data/journal/cycles.jsonl\tdata trade-lab-cycles\tthin
data/journal/cycles_mainnet.jsonl\tdata trade-lab-cycles-mainnet\traw
data/state/orders.json\tdata trade-lab-orders\traw'

read -r host dir < <(python3 - "$REG" "$APP" <<'PY'
import sys, yaml
app = (yaml.safe_load(open(sys.argv[1])) or {}).get("apps", {}).get(sys.argv[2])
if not app: sys.exit(f"FAIL: {sys.argv[2]} not in the registry")
print(app["host"], app.get("dir", "."))
PY
)

if [ "${1:-}" = "--list" ]; then
  while IFS=$'\t' read -r rel title mode; do
    echo "$host: ~/$dir/$rel -> \"$title\" ($mode)"
  done <<<"$FILES"
  exit 0
fi

# ssh straight from the gitignored inventory — no hardcoded machines; the
# journal moves hosts together with the app (edit apps.yml, re-run). Dummy
# vault password: nothing in host vars is encrypted, and .vault_pass would
# cost an `op read` round-trip.
vpf=$(mktemp)
echo data-backup-dummy > "$vpf"
trap 'rm -f "$vpf"' EXIT
INV=$(ANSIBLE_VAULT_PASSWORD_FILE="$vpf" ansible-inventory --list)
read -r ip user key < <(python3 -c '
import json, sys
hv = json.load(sys.stdin)["_meta"]["hostvars"][sys.argv[1]]
print(hv["ansible_host"], hv["ansible_user"], hv["ansible_ssh_private_key_file"])' \
  "$host" <<<"$INV")
key="${key/#\~/$HOME}"
sshc=(ssh -n -o IdentitiesOnly=yes -o ConnectTimeout=15 -i "$key" "$user@$ip")

# Keep = started_at hour on the 6-hour grid. Unparsable lines are KEPT —
# never silently drop data on a format change; the drop count goes to stderr.
thin() {
  python3 -c '
import json, sys
kept = dropped = 0
for line in sys.stdin:
    s = line.strip()
    if not s: continue
    try:
        keep = int(json.loads(s)["started_at"][11:13]) % 6 == 0
    except Exception:
        keep = True
    if keep:
        sys.stdout.write(s + "\n"); kept += 1
    else:
        dropped += 1
print(f"     thinned: kept {kept}, dropped {dropped} hourly-era records", file=sys.stderr)'
}

fail=0
tmp=$(mktemp)
trap 'rm -f "$vpf" "$tmp"' EXIT

while IFS=$'\t' read -r rel title mode; do
  if ! "${sshc[@]}" "cat \"\$HOME/$dir/$rel\"" > "$tmp" 2>/dev/null || [ ! -s "$tmp" ]; then
    echo "FAIL $title — ~/$dir/$rel missing or empty on $host" >&2
    fail=1
    continue
  fi
  if [ "$mode" = "thin" ]; then
    thin < "$tmp" > "$tmp.f" && mv "$tmp.f" "$tmp"
  fi

  # op only reads stdin from a PIPE — a plain file redirect dies with
  # "expected data on stdin but none found" (op 2.35).
  if op item get "$title" --vault "$VAULT" >/dev/null 2>&1; then
    cat "$tmp" | op document edit "$title" --vault "$VAULT" - >/dev/null
    action="updated"
  else
    cat "$tmp" | op document create - --vault "$VAULT" --title "$title" \
      --file-name "${title#data }.${rel##*.}" --tags "$TAG" >/dev/null
    action="created"
  fi

  want=$(shasum -a 256 < "$tmp" | cut -d' ' -f1)
  got=$(op document get "$title" --vault "$VAULT" | shasum -a 256 | cut -d' ' -f1)
  if [ "$want" = "$got" ]; then
    echo "OK   $title ($action, sha256 verified)"
  else
    echo "FAIL $title — hash mismatch after upload" >&2
    fail=1
  fi
done <<<"$FILES"

exit $fail
