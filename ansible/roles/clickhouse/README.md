# clickhouse

Self-hosted **ClickHouse in Docker** — the VkAdsTool stats store, moved off
russia-02 (where it ran as an on-host compose project outside git) onto the fleet
as a reproducible role. Interim home is **finland-01** (alongside the MySQL
primary); the data is a small derived stats set (`stats_daily` ≈ 24k rows).

## What the role does

- Installs Docker Engine (official apt repo; a no-op where the `mysql` role
  already did) and runs `clickhouse-server` via compose, data on a bind mount,
  config in `config.d/zz-server.xml`, users in `users.d/zz-users.xml`.
- Plaintext native/HTTP (9000/8123) publish on **loopback only**; the TLS ports
  (native-secure **9440**, HTTPS **8443**) carry the public endpoint, presenting
  the `*.clickhouse.<zone>` LE cert (copied into a container-readable dir, hot
  re-copied + `SYSTEM RELOAD CONFIG`'d by a certbot renewal hook).
- Users are declared in `users.d` (hot-reloaded); the vault plaintext is hashed to
  `password_sha256_hex` on the host — the clear value never lands on disk.
- Creates databases idempotently (`CREATE DATABASE IF NOT EXISTS`). Table DDL and
  data belong to the app / the data migration, not this role.
- Nightly per-database logical backup (DDL + `Native` data per MergeTree table) →
  tar.gz, age-encrypted + uploaded off-site, driven by a systemd timer.

## Endpoints

- `primary.clickhouse.<zone>` → the primary's WireGuard IP (fleet apps dial it over
  the tunnel; e.g. VkAdsTool on russia-01 → `9440`, `CLICKHOUSE_SECURE=true`).
- `public.clickhouse.<zone>` → the host's public IP, for any off-mesh consumer.
  Both are covered by the `*.clickhouse.<zone>` SAN on the zone's LE lineage.

## Safety: never publish plaintext / un-firewalled

Docker DNATs a published port **before** the nftables `forward` chain, so a
`0.0.0.0` publish never touches the default-drop `input` chain —
`firewall_docker_allow_tcp` is the *only* gate. The role **asserts**: TLS ports on
`0.0.0.0` require `firewall_managed: true`; the plaintext ports must stay on
loopback or a private IP (their wire carries credentials in clear).

## Enable

1. Host is in the `db` group (the `clickhouse` role runs on that play, gated by
   `clickhouse_managed`), `firewall_managed: true`, `tls_managed: true`, and on the
   WireGuard mesh.
2. Add `*.clickhouse.<zone>` to the zone's `tls_zones` SAN set so the LE cert
   covers the endpoints.
3. host_vars: `clickhouse_managed: true`, `clickhouse_tls_enabled: true` + cert
   paths, `clickhouse_databases` / `clickhouse_users`, the `firewall_docker_allow_tcp`
   entries for 9440/8443, and the off-site backup block.
4. Vault: one `vault_clickhouse_<user>` per user (see `all.vault.yml.example`).
5. `make check` then `make deploy`.

## Key variables

| Variable | Default | Notes |
|---|---|---|
| `clickhouse_tls_enabled` | `false` | Present the LE cert on 9440/8443 |
| `clickhouse_tls_publish_address` | `0.0.0.0` | TLS ports; gated by the firewall |
| `clickhouse_plain_publish_address` | `127.0.0.1` | Native/HTTP — loopback only |
| `clickhouse_databases` / `clickhouse_users` | `[]` | User: `{name, password, database, profile?, networks?}` |
| `clickhouse_backup_offsite_enabled` | `false` | age + rclone to Object Storage |

## Migrating data in (dump → load → verify)

`scripts/migrate-clickhouse-data.sh` copies each database's schema + data from a
source host into this server over SSH + `docker exec`, then verifies row counts.
Deploy the role first (empty databases + users), then run it. Manual equivalent
for one table:

```bash
# schema (base tables before dependent views):
ssh SRC "docker exec clickhouse clickhouse-client -q \"SHOW CREATE TABLE \\\`db\\\`.\\\`t\\\`\"" \
  | ssh DST "docker exec -i clickhouse clickhouse-client --multiquery"
# data:
ssh SRC "docker exec clickhouse clickhouse-client -q \"SELECT * FROM \\\`db\\\`.\\\`t\\\` FORMAT Native\"" \
  | ssh DST "docker exec -i clickhouse clickhouse-client -q \"INSERT INTO \\\`db\\\`.\\\`t\\\` FORMAT Native\""
```

## Rotating a password

Users are declared in `users.d` from the vault. Rotate by editing the vault entry
and re-deploying — the templated `users.d/zz-users.xml` is hot-reloaded (no
restart). (Unlike MySQL's `IF NOT EXISTS`, a changed hash *is* applied here.)

## Backups & restore

Nightly tar.gz per database under `clickhouse_backup_dir` (age-encrypted copy
off-site; private identity ONLY in 1Password). Restore round-trip:

```bash
tar -xzf <db>-YYYYmmdd-HHMMSS.tar.gz -C /tmp && cd /tmp/<db>-*
# recreate tables in tables.order, then load MergeTree data:
while read t; do docker exec -i clickhouse clickhouse-client --multiquery < "$t.sql"; done < tables.order
for f in *.native; do t=${f%.native}; \
  docker exec -i clickhouse clickhouse-client -q "INSERT INTO \`<db>\`.\`$t\` FORMAT Native" < "$f"; done
```
