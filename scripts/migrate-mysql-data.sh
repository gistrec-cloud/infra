#!/usr/bin/env bash
# Copy each validated app database from the managed Yandex cluster into the
# self-hosted primary on finland-01: dump -> load -> verify row counts.
# Reads passwords from the "mysql <user>" 1P items (pull-mysql-creds.sh made them).
#
# The managed cluster is only READ; the apps keep running on it until you repoint
# their .env. Idempotent BEFORE cutover (a re-load drops+recreates the tables).
# Do NOT re-run for a DB whose app already writes to the self-host — it would drop
# the live rows.
#
#   scripts/migrate-mysql-data.sh              # all validated DBs
#   scripts/migrate-mysql-data.sh dnd-crime    # only the named user(s)
# No `ssh -n`: it would /dev/null the piped `bash -s <<REMOTE` heredoc → the remote
# runs an empty script (silent no-op, exit 0). The loop is a `for`, needs no -n.
VAULT="Gistrec Cloud"
SSH=(ssh -o ConnectTimeout=20 -o IdentitiesOnly=yes -i "$HOME/.ssh/vps-finland-01.pub" gistrec@62.238.12.36)

want=("$@")
users=$(op item list --vault "$VAULT" --tags mysql-managed --format json \
  | python3 -c 'import json,sys
for i in json.load(sys.stdin):
    if i["title"].startswith("mysql "): print(i["title"][6:])' | sort -u)
[ -n "$users" ] || { echo "no mysql-managed 1P items — run pull-mysql-creds.sh first"; exit 1; }

field() { python3 -c 'import json,sys
d=json.load(sys.stdin)
print(next((f["value"] for f in d.get("fields",[]) if f.get("id")==sys.argv[1] or f.get("label")==sys.argv[1]),""))' "$1"; }

ok=0 bad=0
for u in $users; do
  if [ ${#want[@]} -gt 0 ]; then printf '%s\n' "${want[@]}" | grep -qxF "$u" || continue; fi
  j=$(op item get "mysql $u" --vault "$VAULT" --format json) || { echo "FAIL $u: op item get"; bad=$((bad+1)); continue; }
  pw=$(printf '%s' "$j"  | field password)
  host=$(printf '%s' "$j" | field host); host=${host:-public.mysql.gistrec.cloud}
  db=$(printf '%s' "$j"  | field database); db=${db:-$u}
  [ -n "$pw" ] || { echo "FAIL $u: no password in 1P item"; bad=$((bad+1)); continue; }
  pb64=$(printf '%s' "$pw" | base64 | tr -d '\n')

  echo "--- $u  (db=$db, host=$host) ---"
  if "${SSH[@]}" bash -s "$pb64" "$host" "$db" <<'REMOTE'
set -euo pipefail
PW=$(printf %s "$1" | base64 -d); MH="$2"; DB="$3"; CA="$HOME/.mysql/root.crt"
m() { MYSQL_PWD="$PW" mysql -h "$MH" -u "$DB" --ssl-mode=VERIFY_CA --ssl-ca "$CA" -N "$@"; }
self() { sudo docker exec -i mysql sh -c 'MYSQL_PWD="$MYSQL_ROOT_PASSWORD" mysql -N'; }
MYSQL_PWD="$PW" mysqldump -h "$MH" -u "$DB" --ssl-mode=VERIFY_CA --ssl-ca "$CA" \
  --no-tablespaces --single-transaction --routines --triggers --events \
  --set-gtid-purged=OFF --databases "$DB" > /tmp/mig.sql 2>/tmp/mig.err \
  || { echo "  DUMP FAILED:"; sed 's/^/    /' /tmp/mig.err; exit 1; }
self < /tmp/mig.sql
mm=0
for t in $(m -e "SELECT table_name FROM information_schema.tables WHERE table_schema='$DB'"); do
  a=$(m -e "SELECT COUNT(*) FROM \`$DB\`.\`$t\`")
  b=$(echo "SELECT COUNT(*) FROM \`$DB\`.\`$t\`" | self)
  [ "$a" = "$b" ] || { echo "  MISMATCH $t: managed=$a self=$b"; mm=1; }
done
rm -f /tmp/mig.sql /tmp/mig.err
nt=$(echo "SELECT COUNT(*) FROM information_schema.tables WHERE table_schema='$DB'" | self)
[ "$mm" = 0 ] && echo "  OK: $nt tables, row counts verified" || { echo "  VERIFY MISMATCH"; exit 1; }
REMOTE
  then ok=$((ok+1)); else bad=$((bad+1)); fi
done
echo "== done: $ok migrated+verified, $bad failed =="
[ "$bad" -eq 0 ]
