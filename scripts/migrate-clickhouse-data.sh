#!/usr/bin/env bash
# Copy ClickHouse databases from russia-02 into the self-hosted server on
# finland-01: recreate schema → copy data → verify row counts. Both ends are
# reached over SSH + `docker exec clickhouse-client` as the default admin (loopback
# inside the container), so NO ClickHouse password is needed anywhere. Data streams
# source → controller → target in FORMAT Native (2-3 MB — trivial).
#
# Idempotent BEFORE cutover: a re-run drops + recreates the databases' tables. Do
# NOT run for a database the app already writes to on finland-01 — it drops the
# live rows. Deploy the clickhouse role first (it creates the databases + users).
#
# MaterializedViews are created LAST, after the base data is loaded, so an insert
# into a source table (stats_raw) never double-writes its target (stats_daily).
#
#   scripts/migrate-clickhouse-data.sh                 # both databases below
#   scripts/migrate-clickhouse-data.sh vk-ads-tool     # only the named database(s)
set -euo pipefail

SRC_SSH="ssh -o ConnectTimeout=20 -o BatchMode=yes vk-ads-tool@84.252.139.137"
DST_SSH="ssh -o ConnectTimeout=20 -o BatchMode=yes -o IdentitiesOnly=yes -i $HOME/.ssh/vps-finland-01.pub gistrec@62.238.12.36"
# --multiquery reads the query from stdin, so backtick-quoted identifiers never
# hit a remote shell command line (no ssh quoting hell). russia-02's login user is
# in the docker group; finland-01's gistrec needs sudo (passwordless) for docker.
CH_SRC="docker exec -i clickhouse clickhouse-client --multiquery"
CH_DST="sudo docker exec -i clickhouse clickhouse-client --multiquery"
DATABASES="vk-ads-tool vk-ads-tool-test"

want="$*"

ch_src() { $SRC_SSH "$CH_SRC"; }
ch_dst() { $DST_SSH "$CH_DST"; }
q_src() { printf '%s' "$1" | ch_src; }
q_dst() { printf '%s' "$1" | ch_dst; }

ok=0 bad=0
for db in $DATABASES; do
  if [ -n "$want" ]; then printf '%s\n' $want | grep -qxF "$db" || continue; fi
  echo "--- $db ---"

  base=$(q_src "SELECT name FROM system.tables WHERE database='$db' AND engine LIKE '%MergeTree%' AND NOT is_temporary ORDER BY name FORMAT TabSeparatedRaw") \
    || { echo "  FAIL: list base tables"; bad=$((bad + 1)); continue; }
  views=$(q_src "SELECT name FROM system.tables WHERE database='$db' AND engine IN ('MaterializedView','View') ORDER BY name FORMAT TabSeparatedRaw") \
    || { echo "  FAIL: list views"; bad=$((bad + 1)); continue; }

  fail=0
  q_dst "CREATE DATABASE IF NOT EXISTS \`$db\`" || fail=1
  # Drop views before base tables (a view depends on its source/target).
  for t in $views $base; do q_dst "DROP TABLE IF EXISTS \`$db\`.\`$t\`" || fail=1; done

  # Recreate base tables, load their data, THEN recreate the views.
  for t in $base; do
    ddl=$(q_src "SHOW CREATE TABLE \`$db\`.\`$t\` FORMAT TabSeparatedRaw") || { fail=1; break; }
    printf '%s' "$ddl" | ch_dst || { fail=1; break; }
  done
  [ $fail = 0 ] || { echo "  FAIL: base schema"; bad=$((bad + 1)); continue; }

  # Load via --query (not stdin): clickhouse-client cannot read an INSERT query
  # and its Native data from ONE stdin stream. The dash-name db goes as the
  # --database flag value (not a SQL identifier), so the plain table identifier
  # needs no backticks — sidestepping ssh quoting.
  for t in $base; do
    # Skip empty tables: SELECT ... FORMAT Native yields no block, and the INSERT
    # then errors "No data to insert" (Code 108). Schema is already created above.
    n=$(q_src "SELECT count() FROM \`$db\`.\`$t\` FORMAT TabSeparatedRaw")
    [ "$n" = 0 ] && { echo "  skip data $t (0 rows)"; continue; }
    load="sudo docker exec -i clickhouse clickhouse-client --database $db --query 'INSERT INTO $t FORMAT Native'"
    q_src "SELECT * FROM \`$db\`.\`$t\` FORMAT Native" | $DST_SSH "$load" || { fail=1; break; }
  done
  [ $fail = 0 ] || { echo "  FAIL: data copy"; bad=$((bad + 1)); continue; }

  for t in $views; do
    ddl=$(q_src "SHOW CREATE TABLE \`$db\`.\`$t\` FORMAT TabSeparatedRaw") || { fail=1; break; }
    printf '%s' "$ddl" | ch_dst || { fail=1; break; }
  done
  [ $fail = 0 ] || { echo "  FAIL: view schema"; bad=$((bad + 1)); continue; }

  # Verify row counts on the base tables (views hold no own data).
  mm=0
  for t in $base; do
    a=$(q_src "SELECT count() FROM \`$db\`.\`$t\` FORMAT TabSeparatedRaw")
    b=$(q_dst "SELECT count() FROM \`$db\`.\`$t\` FORMAT TabSeparatedRaw")
    [ "$a" = "$b" ] || { echo "  MISMATCH $t: russia-02=$a finland-01=$b"; mm=1; }
  done
  if [ $mm = 0 ]; then
    echo "  OK: base [$(echo $base | tr '\n' ' ')] + views [$(echo $views | tr '\n' ' ')] verified"
    ok=$((ok + 1))
  else
    bad=$((bad + 1))
  fi
done

echo "== done: $ok migrated+verified, $bad failed =="
[ $bad -eq 0 ]
