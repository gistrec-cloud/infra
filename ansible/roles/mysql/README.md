# mysql

Self-hosted **MySQL 8.0 in Docker** — a **GTID primary/replica pair** on the
fleet. It replaced the managed Yandex cluster, whose bill was all-or-nothing (a
minimum-size instance): every database moved off and the cluster was destroyed
2026-07-21 (tombstone: `terraform/yandex/mysql.tf`). The registry of databases
and users — 23 databases today — lives in `ansible/group_vars/db.yml`
(gitignored; `db.yml.example` is the template in git), not in host_vars.

- **primary** — currently **finland-01** (interim; the writable copy, binlog +
  GTID on). Serves fleet apps over WireGuard and the YC Cloud Functions over a
  public TLS endpoint. Planned to move to russia-03 (the RF timeweb VPS) later
  via replica-promote.
- **replica** — a `super_read_only` standby, **russia-03** since 2026-08-19 (the
  first live one), pulls from the primary over the **WireGuard tunnel** (see the
  `wireguard` role). Promotable to primary in ~2 minutes (runbook below).
  Endpoints: `primary.mysql.gistrec.cloud` (always-primary, flips on promote) and
  `replica-NN.mysql.gistrec.cloud`.

The whole dataset is <1 GB (clear-transcript-bot ≈ 860 MB is 89% of it), so a 1 GB
buffer pool caches everything on both nodes.

## What the role does

- Installs Docker Engine (official apt repo) and runs `mysql:8.0` via compose,
  data on a bind mount, config in `conf.d` mirroring the retired managed
  cluster's `sql_mode` + `utf8mb4`.
- `mysql_role`-aware config: `primary`/`replica` get `server_id` + GTID binlog;
  a `replica` also gets a relay log, and `tasks/replica.yml` `SET PERSIST`s
  `read_only` + `super_read_only` once replication is up (not in the cnf: there
  they hit the entrypoint's init server too, which then can't create root).
- **primary** creates the replication user; **replica** points at the source over
  WireGuard and `START REPLICA` (idempotent — no-op once running).
- Creates the `group_vars/db.yml` databases/users idempotently on non-replicas
  (a replica gets them via replication).
- Nightly per-database `mysqldump` + rotation via a systemd timer.

## Safety: never publish MySQL without the firewall

Docker DNATs a published port **before** the nftables `forward` chain, so a
`0.0.0.0` publish never touches the default-drop `input` chain —
`firewall_docker_allow_tcp` is the *only* gate. The role **asserts**
`firewall_managed: true` (or a non-`0.0.0.0` `mysql_publish_address`) first. The
primary publishes on `0.0.0.0` **and the firewall opens 3306 to `0.0.0.0/0`** —
public, like the managed cluster it replaced (public IP, no security group): the
guard is password auth plus the `*.mysql.gistrec.cloud` cert, which mysqld only
offers (no `require_secure_transport`, no `REQUIRE SSL`) — clients must dial with
`--ssl-mode=REQUIRED` themselves. The fleet uses the wg name; the public endpoint
exists for the off-mesh YC Cloud Functions. The replica publishes on `127.0.0.1`
(outbound-only).

## Enable

1. Add both hosts to the `db` group in `inventory/hosts.yml`; the role runs where
   `mysql_managed: true`. Mesh membership is not a group — set `wireguard_ip` +
   `wireguard_pubkey` in host_vars (the `wireguard` role is gated on
   `wireguard_ip is defined`).
2. Bring up WireGuard first (keys per the `wireguard` role README).
3. Copy `host_vars/db-01.yml.example` / `db-02.yml.example` to the real host
   names, fill fleet IPs, `mysql_role` and `wireguard_pubkey`.
4. Copy `group_vars/db.yml.example` → `group_vars/db.yml` (gitignored) and fill
   `mysql_databases` / `mysql_users` there — a cluster property, not a host one,
   so it survives a promotion. (Restore the real file from the 1Password Document
   "infra repo-private files" — see `scripts/backup-repo-files.sh`.)
5. Vault: `vault_mysql_root_password`, `vault_mysql_replication_password`, the
   per-user passwords, and `vault_wg_privkey_<host>` (see `all.vault.yml.example`).
6. `make check` then `make deploy`.

## Key variables

| Variable | Default | Notes |
|---|---|---|
| `mysql_role` | `standalone` | `primary` \| `replica` \| `standalone` |
| `mysql_server_id` | `1` | Unique across the topology (primary=1, replica=2) |
| `mysql_innodb_buffer_pool_size` | `256M` | Set `1G` on primary/replica |
| `mysql_replication_source_host` | `""` | Replica only — the primary's `wg0` IP |
| `mysql_publish_address` | `0.0.0.0` | Replica sets `127.0.0.1` |
| `mysql_databases` / `mysql_users` | `[]` | In `group_vars/db.yml`; applied where `mysql_role != replica` |

## History: migration off the managed cluster (done)

Every database moved from the shared managed Yandex cluster onto this self-hosted
primary over 2026-07-20/21, and the cluster was destroyed 2026-07-21 after an S3
restore-drill — tombstone in `terraform/yandex/mysql.tf`. Beware the dump recipes
in git history: `public.mysql.gistrec.cloud` was repointed at the self-hosted
primary in that same cutover, so "dump from managed" now reads the live primary.

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
# FLUSH PRIVILEGES after the load: the dump writes mysql.user as table rows,
# invisible to the in-memory account cache until flushed — replicated
# ALTER USER / GRANT statements fail with 1396 otherwise (russia-03, 2026-08-19).
docker exec mysql sh -c 'MYSQL_PWD="$MYSQL_ROOT_PASSWORD" mysql -uroot -e "FLUSH PRIVILEGES"'
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
-- PERSIST, not GLOBAL: replica.yml persisted these ON, so a GLOBAL-only flip
-- comes back read-only at the next container restart.
SET PERSIST super_read_only = OFF; SET PERSIST read_only = OFF;
SQL
```
Then: set `mysql_role: primary` in its host_vars, publish 3306
(`mysql_publish_address: 0.0.0.0` + a `firewall_docker_allow_tcp` entry) and turn
on TLS (`mysql_tls_enabled` + the cert paths — a `tls_managed` standby already
issues the `*.mysql` SAN on its zone lineage, it just doesn't serve it). Flip the
ttl-60 records in `terraform/dns/terraform.tfvars`: `primary.mysql` → the new
primary's wg IP, `public.mysql` → its public IP, `replica-01.mysql` → the demoted
host's wg IP. **Cloud Functions caveat:** the YC functions (budget-explorer,
realmctl) can't reach the mesh, so that public record is their only path — over
the internet, guarded by auth + TLS. The old primary rejoins as a replica:
cleanly via GTID if its data survived, otherwise seed it first (above). Make the
flip durable in git afterwards.

Backups need no edit: `mysql_backup_enabled`, the off-site S3/age settings and
the `backup_marker_stale` filecheck markers all live in `group_vars/db.yml` and
key off `mysql_role`, so they follow the flip on both hosts. Re-run the play on
the demoted host too — otherwise its frozen `.last-success` keeps alarming.

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

**Off-site** (opt-in, `mysql_backup_offsite_enabled`): every fresh dump is
`age`-encrypted and uploaded to S3-compatible Object Storage with a write-only
key (SA `mysql-backup`, id/secret in the vault). The private age identity lives
ONLY in 1Password — without it the copies are unreadable. Retention there is a
bucket lifecycle rule, since the key can't prune. On finland-01: bucket
`gistrec-cloud`, prefix `mysql/<host>/`.

## Backlog

- Dedicated persistent volume for `mysql_data_dir` (the data sits on the host's
  boot disk today).
- Optional: run backups on the replica to offload the primary.
