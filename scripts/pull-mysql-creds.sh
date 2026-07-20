#!/usr/bin/env bash
# Pull managed-MySQL credentials out of the 1Password dotenv backups and store
# each as a "mysql <user>" 1P item, so the self-host migration can reuse the
# existing passwords (only the app's DB *host* then changes, not the password).
#
# RUN THIS YOURSELF — it reads .env content (from 1P), which the assistant is
# barred from touching. It is read-only on the managed cluster and only
# creates/updates "mysql <user>" items in 1Password; it never edits an app .env.
#
#   scripts/pull-mysql-creds.sh
#
# For every dotenv-backup document it: extracts a MySQL host/user/password/db,
# skips creds that don't point at the managed cluster, VALIDATES them by logging
# in to managed from finland-01, then upserts the "mysql <user>" item. Reports
# one line per document; nothing secret is printed.
set -euo pipefail

VAULT="Gistrec Cloud"
# finland-01 validates: it has the mysql client + the Yandex CA (~/.mysql/root.crt)
# and can reach the managed public endpoint.
# -n: stdin from /dev/null so this ssh (inside the read loop) can't swallow the
# loop's own input.
FINLAND=(ssh -n -o ConnectTimeout=20 -o IdentitiesOnly=yes -i "$HOME/.ssh/vps-finland-01.pub" gistrec@62.238.12.36)
# Excluded (per request / Cloud-Function-written, migrated later with the functions).
EXCLUDE="clear-transcript-bot clear-transcript-bot-ro clear-transcript-bot-test realmctl budget-explorer"

command -v op >/dev/null || { echo "need the 1Password CLI (op)"; exit 1; }

docs=$(op item list --vault "$VAULT" --tags dotenv-backup --format json \
  | python3 -c 'import json,sys
for i in json.load(sys.stdin): print(i["id"], i["title"])')
[ -n "$docs" ] || { echo "no dotenv-backup documents found in \"$VAULT\""; exit 1; }

echo "== scanning $(printf '%s\n' "$docs" | grep -c .) dotenv backups for managed-MySQL creds =="
stored=0 skipped=0 failed=0

while read -r id title <&3; do
  [ -n "$id" ] || continue
  app=${title#dotenv }

  envtext=$(op document get "$id" --vault "$VAULT" 2>/dev/null) || { echo "—    $title: cannot read document"; continue; }

  # Extract host<TAB>user<TAB>pass<TAB>db from a mysql:// URL, a Go tcp() DSN, or
  # discrete MYSQL_*/DB_* vars. Prints nothing if no MySQL creds are present.
  line=$(ENVTEXT="$envtext" python3 <<'PY'
import os, re, urllib.parse
vars={}
for l in os.environ['ENVTEXT'].splitlines():
    l=l.strip()
    if l.startswith('export '): l=l[7:]
    if not l or l.startswith('#') or '=' not in l: continue
    k,v=l.split('=',1); vars[k.strip()]=v.strip().strip('"').strip("'")
res=None
for v in vars.values():
    m=re.match(r'^(?:mysql|mariadb)://([^:/@]+):([^@]*)@([^:/]+)(?::\d+)?/([^?]+)',v)
    if m: res=(m.group(3),m.group(1),urllib.parse.unquote(m.group(2)),m.group(4)); break
if not res:
    for v in vars.values():
        m=re.match(r'^([^:/@]+):([^@]*)@tcp\(([^:)]+)(?::\d+)?\)/([^?]+)',v)
        if m: res=(m.group(3),m.group(1),m.group(2),m.group(4)); break
if not res:
    def pick(*n):
        for x in n:
            if vars.get(x): return vars[x]
        return ''
    h=pick('MYSQL_HOST','DB_HOST','DATABASE_HOST','MYSQLHOST','DBHOST')
    u=pick('MYSQL_USER','DB_USER','DATABASE_USER','DB_USERNAME','MYSQLUSER','DBUSER')
    p=pick('MYSQL_PASSWORD','MYSQL_PWD','DB_PASSWORD','DB_PASS','DATABASE_PASSWORD','DB_PASSWD','MYSQLPASSWORD','DBPASSWORD','DB_PWD')
    d=pick('MYSQL_DATABASE','DB_NAME','DB_DATABASE','DATABASE_NAME','MYSQLDATABASE','DBNAME')
    if h and u and p: res=(h,u,p,d or u)
if res:
    print("CRED\t%s\t%s\t%s\t%s" % res)
else:
    dbish=[k for k in vars if re.search(r'(?i)mysql|maria|database|(?:^|_)db(?:_|$)|(?:^|_)dsn$|_url$', k)]
    print("DIAG\t" + (", ".join(dbish) if dbish else "(no db-ish vars)"))
PY
)
  if [ "${line%%$'\t'*}" = "DIAG" ]; then
    echo "—    $title: no parseable MySQL creds — vars seen: ${line#DIAG$'\t'}"
    skipped=$((skipped+1)); continue
  fi
  IFS=$'\t' read -r _kind host user pass db <<<"$line"
  db=${db:-$user}

  case "$host" in
    *mysql.gistrec.cloud|*.mdb.yandexcloud.net) ;;
    *) echo "—    $title: MySQL host '$host' is not managed — skip"; skipped=$((skipped+1)); continue ;;
  esac
  case " $EXCLUDE " in *" $user "*) echo "skip $title: '$user' excluded"; skipped=$((skipped+1)); continue ;; esac

  # Validate against managed (pass carried base64 so no quoting/ps leak of the value).
  pb64=$(printf '%s' "$pass" | base64 | tr -d '\n')
  if "${FINLAND[@]}" "MYSQL_PWD=\$(printf %s '$pb64' | base64 -d) mysql -h '$host' -u '$user' --ssl-mode=REQUIRED --ssl-ca ~/.mysql/root.crt -N -e 'SELECT 1' >/dev/null 2>&1"; then
    :
  else
    echo "FAIL $title: creds for '$user' did NOT authenticate to managed ($host)"; failed=$((failed+1)); continue
  fi

  existing=$(op item list --vault "$VAULT" --format json | python3 -c "import json,sys
print(next((i['id'] for i in json.load(sys.stdin) if i.get('title')=='mysql $user'),''))")
  if [ -n "$existing" ]; then
    op item edit "$existing" --vault "$VAULT" "password=$pass" "host[text]=$host" "database[text]=$db" >/dev/null
    echo "OK   mysql $user (validated, updated)"
  else
    op item create --category login --vault "$VAULT" --title "mysql $user" \
      "username=$user" "password=$pass" "host[text]=$host" "database[text]=$db" --tags mysql-managed >/dev/null
    echo "OK   mysql $user (validated, created)"
  fi
  stored=$((stored+1))
done 3<<<"$docs"

echo "== done: $stored stored, $skipped skipped, $failed failed =="
[ "$failed" -eq 0 ]
