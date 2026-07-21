# mysql

Self-hosted **MySQL 8.0 in Docker** — replaces the managed Yandex cluster
(`terraform/yandex/mysql.tf`) with a **GTID primary/replica pair** on the fleet.
The managed bill is all-or-nothing (a minimum-size instance), so the goal is to
move **all 16 databases** off it, then delete the cluster.

- **primary** — currently **finland-01** (interim; the writable copy, binlog +
  GTID on). Serves fleet apps over WireGuard; Cloud Functions will reach it over a
  public TLS endpoint. Moves to a RF VPS (timeweb) later via replica-promote.
- **replica** — a `super_read_only` standby (first one ~2026-07-21), pulls from
  the primary over the **WireGuard tunnel** (see the `wireguard` role). Promotable
  to primary in ~2 minutes (runbook below). Endpoints: `primary.mysql.gistrec.cloud`
  (always-primary, flips on promote) and `replica-NN.mysql.gistrec.cloud`. NB: the
  primary is LIVE (empty) on finland-01 since 2026-07-20; migrating data off the
  managed Yandex cluster is in progress.

The whole dataset is <1 GB (clear-transcript-bot ≈ 860 MB is 89% of it), so a 1 GB
buffer pool caches everything on both nodes.

## What the role does

- Installs Docker Engine (official apt repo) and runs `mysql:8.0` via compose,
  data on a bind mount, config in `conf.d` mirroring the managed `sql_mode` + `utf8mb4`.
- `mysql_role`-aware config: `primary`/`replica` get `server_id` + GTID binlog;
  `replica` also gets `super_read_only`.
- **primary** creates the replication user; **replica** points at the source over
  WireGuard and `START REPLICA` (idempotent — no-op once running).
- Creates databases/users idempotently on non-replicas (replica gets them via
  replication).
- Nightly per-database `mysqldump` + rotation via a systemd timer.

## Safety: never publish MySQL without the firewall

Docker DNATs a published port **before** the nftables `forward` chain, so a
`0.0.0.0` publish never touches the default-drop `input` chain —
`firewall_docker_allow_tcp` is the *only* gate. The role **asserts**
`firewall_managed: true` (or a non-`0.0.0.0` `mysql_publish_address`) first. The
primary publishes on `0.0.0.0` and allows only the replica's tunnel IP + the
Cloud Functions range; the replica publishes on `127.0.0.1` (outbound-only).

## Enable

1. Add both hosts to the `db` and `wireguard` groups in `inventory/hosts.yml`.
2. Bring up WireGuard first (keys per the `wireguard` role README).
3. Copy `host_vars/db-01.yml.example` / `db-02.yml.example` to the real host
   names, fill fleet IPs, the DB/user lists (primary), and `wireguard_pubkey`.
4. Vault: `vault_mysql_root_password`, `vault_mysql_replication_password`, the
   per-user passwords, and `vault_wg_privkey_<host>` (see `all.vault.yml.example`).
5. `make check` then `make deploy`.

## Key variables

| Variable | Default | Notes |
|---|---|---|
| `mysql_role` | `standalone` | `primary` \| `replica` \| `standalone` |
| `mysql_server_id` | `1` | Unique across the topology (primary=1, replica=2) |
| `mysql_innodb_buffer_pool_size` | `256M` | Set `1G` on primary/replica |
| `mysql_replication_source_host` | `""` | Replica only — the primary's `wg0` IP |
| `mysql_publish_address` | `0.0.0.0` | Replica sets `127.0.0.1` |
| `mysql_databases` / `mysql_users` | `[]` | Primary only; replica gets them via replication |

## Migration order (kill the managed cluster last)

1. Stand up the **primary** empty, `make deploy` to db-01.
2. Migrate data per database — dump from managed, load into the primary. Let the
   primary assign fresh GTIDs (`--set-gtid-purged=OFF`):
   ```bash
   mysqldump --single-transaction --routines --triggers --set-gtid-purged=OFF \
     -h public.mysql.gistrec.cloud --ssl-mode=REQUIRED -u <user> -p <db> > <db>.sql
   docker exec -i mysql sh -c 'MYSQL_PWD="$MYSQL_ROOT_PASSWORD" mysql -uroot <db>' < <db>.sql
   ```
3. Repoint each app / VPC-attached Cloud Function at the primary; verify.
4. Bootstrap the **replica** (below).
5. Only when everything is healthy on self-host: remove the databases/users from
   `terraform/yandex/mysql.tf` and `terraform apply`, then delete the cluster.
   This is what actually stops the 3 698 ₽/mo — do it last.

## Bootstrap the replica

An empty server can't catch up via AUTO_POSITION once the primary purges the
needed GTIDs — seed it from a primary dump first:

```bash
# On the primary — dump WITH gtid state:
docker exec mysql sh -c 'MYSQL_PWD="$MYSQL_ROOT_PASSWORD" \
  mysqldump --all-databases --single-transaction --routines --triggers \
  --set-gtid-purged=ON -uroot' | gzip > /tmp/seed.sql.gz
# Copy /tmp/seed.sql.gz to the replica, then load it:
gunzip -c seed.sql.gz | docker exec -i mysql sh -c 'MYSQL_PWD="$MYSQL_ROOT_PASSWORD" mysql -uroot'
# Now `make deploy` to db-02 (or just re-run) — tasks/replica.yml runs
# CHANGE REPLICATION SOURCE + START REPLICA. Verify:
docker exec mysql sh -c 'MYSQL_PWD="$MYSQL_ROOT_PASSWORD" mysql -uroot -e "SHOW REPLICA STATUS\G"' \
  | grep -E 'Replica_(IO|SQL)_Running|Seconds_Behind_Source|Last_.*Error'
# Want: both Running: Yes, Seconds_Behind_Source: 0, no errors.
```

## Promote the replica to primary (~2 min, manual)

Async WAN replication → **no auto-failover** (split-brain risk). Promote by hand:

```bash
# On the replica (db-02):
docker exec -i mysql sh -c 'MYSQL_PWD="$MYSQL_ROOT_PASSWORD" mysql -uroot' <<'SQL'
STOP REPLICA; RESET REPLICA ALL;
SET GLOBAL super_read_only = OFF; SET GLOBAL read_only = OFF;
SQL
```
Then: set `mysql_role: primary` in its host_vars, open 3306 to consumers
(publish + firewall), and repoint apps. **Cloud Functions caveat:** they reach
russia-01 privately via the Yandex VPC; a promoted external replica (e.g.
finland-01) is off-VPC, so they'd connect over the public internet
(function egress IPs aren't fixed) —
needs TLS/a gateway for that path. When russia-01 returns, it rejoins cleanly as
a replica (GTID). Make the flip durable in git afterwards.

## Rotating a password

`CREATE USER IF NOT EXISTS` never overwrites an existing password. Rotate by hand:

```bash
docker exec -i mysql sh -c 'MYSQL_PWD="$MYSQL_ROOT_PASSWORD" mysql -uroot' \
  <<< "ALTER USER 'app'@'%' IDENTIFIED BY 'new-password';"
```

## Backups & restore

Nightly `mysqldump` → gzip under `mysql_backup_dir`, rotated. A replica is **not**
a backup (a bad `DROP` replicates in milliseconds). Test the round-trip once:

```bash
gunzip -c /var/backups/mysql/<db>-YYYYmmdd-HHMMSS.sql.gz | \
  docker exec -i mysql sh -c 'MYSQL_PWD="$MYSQL_ROOT_PASSWORD" mysql -uroot'
```

## Backlog

- Off-site upload of dumps to Object Storage (client-side encrypted; SA key in vault).
- Dedicated persistent disk for `mysql_data_dir` (boot disks are `auto_delete`).
- Optional: run backups on the replica to offload the primary.
