# infra

[![CI](https://github.com/gistrec-cloud/infra/actions/workflows/ci.yml/badge.svg)](https://github.com/gistrec-cloud/infra/actions/workflows/ci.yml)

Infrastructure as code for the **gistrec-cloud** fleet.

- **Ansible** configures what lives *inside* the servers — base hardening, firewall, nginx, registry-driven apps (pm2 / static / docker / cron), self-hosted databases, monitoring.
- **Terraform** manages cloud resources — DNS (Cloudflare + Porkbun), AWS Lambda, the Hetzner and Timeweb servers, and Yandex Cloud (Object Storage, Cloud Functions, IAM/Lockbox).

The repository is deliberately split into **code** (public, here) and **live data** (private, never committed): real inventory, IPs, tokens and state stay out of git. Everything you see here uses placeholders — copy the `*.example` files, fill them locally, and they are already covered by `.gitignore`.

Run **`brew install pre-commit && make hooks`** after cloning — nothing in `.pre-commit-config.yaml` runs without that binary, and its absence is silent. Alongside gitleaks and the linters it installs a check that refuses any public IPv4 in a tracked file: `.gitignore` protects whole files, this catches the address pasted into a comment or a README.

## Architecture

```
   registrar (reg.ru / godaddy)          ┌──────────────┐          ┌──────────────┐
   nameservers delegated to  ──────────► │  Cloudflare  │─── NS ──►│  Gcore  DNS  │  terraform/gcore —
                                         │     DNS      │  for a   │  geo-routed  │  a few projects answer
                                         └──────┬───────┘  few     └──────┬───────┘  with a different host
                                                │  A/CNAME names          │  depending on visitor country,
                                                │                         │  so latency-sensitive traffic
                                                │                         │  lands on a nearby VPS
                    ┌───────────────────────────┼─────────────────────────┴───┐
                    ▼                           ▼                             ▼
              ┌───────────┐               ┌───────────┐                 ┌───────────┐
              │  web-01   │               │  web-02   │                 │    ...    │
              │  nginx    │◄──── wg0 ────►│  nginx    │                 │           │   Ansible-managed
              │  pm2/node │               │  pm2/node │                 │           │   (ansible/)
              │  netdata  │               │  netdata  │                 │           │
              │  nft+f2b  │               │  nft+f2b  │                 │           │
              └─────┬─────┘               └─────┬─────┘                 └───────────┘
                    │                           │        wg0 = WireGuard mesh (10.10.0.0/24) —
                    └─────────────┬─────────────┘        encrypted host↔host traffic, opt-in per host
                                  │  app SQL
                                  ▼
                        ┌───────────────────┐
                        │   MySQL 8.0       │   ansible/roles/mysql — GTID primary in Docker on
                        │  (self-hosted)    │   finland-01, promotable replica on russia-03,
                        └───────────────────┘   replication over wg0; 3306 public (TLS + auth)
                                                — managed Yandex cluster destroyed 2026-07-21

              ┌───────────────────┐
              │  k3s (single node)│   ansible/roles/k3s — on a host shared with someone else's
              │  API :6443        │   service, so the firewall role never runs there: the
              │  flannel + kubelet│   existing ufw stays, and the role only adds its own narrow
              └─────────┬─────────┘   rules. Joined wg0 as 10.10.0.2 (as `wg-fleet` — the
                        │             neighbour holds wg0…wg19), which is how the API reaches
                        └──── wg ───► kubectl and how its metrics reach the netdata parent.
                                      6443 is open on the tunnel only, closed to the internet.
```

## Layout

```
infra/
├── ansible/
│   ├── ansible.cfg
│   ├── requirements.yml          # Galaxy collections
│   ├── site.yml                  # wires roles to host groups
│   ├── apps.yml                  # (gitignored) deployed-apps registry — what runs where
│   ├── inventory/hosts.yml       # (gitignored) real hosts — copy from .example
│   ├── group_vars/               # non-secret defaults + vault; db.yml (gitignored) = MySQL registry
│   ├── host_vars/                # per-host knobs (opt-in roles, wg IPs, …)
│   ├── files/                    # netdata alarms + (gitignored) vhosts, CI control scripts
│   └── roles/
│       ├── common/               # users, SSH hardening, base packages
│       ├── firewall/             # nftables + fail2ban
│       ├── nginx/                # reverse proxy, vhosts from the registry
│       ├── tls/                  # per-zone wildcard certs (DNS-01) — fleet material
│       ├── nodeapp/              # early Node.js/pm2 runtime + legacy apps
│       ├── apppm2/               # registry-driven pm2 apps (clone or CI artifact)
│       ├── appstatic/            # registry-driven static bundles
│       ├── appdocker/            # registry-driven docker dependencies
│       ├── appcron/              # registry-driven cron jobs
│       ├── registry_manifest/    # shared ownership-manifest lifecycle
│       ├── docker_runtime/       # shared Docker Engine + Compose bootstrap
│       ├── container_tls/        # shared container-readable TLS primitives
│       ├── netdata/              # monitoring agent
│       ├── wireguard/            # private encrypted mesh between fleet hosts
│       ├── chrony/               # opt-in time sync
│       ├── breakglass/           # emergency rescue user, keys outside home dirs
│       ├── clickhouse/           # self-hosted ClickHouse (Docker), TLS ports + S3 backups
│       ├── mysql/                # self-hosted MySQL (Docker), primary/replica
│       ├── k3s/                  # single-node Kubernetes on a shared host, under its existing ufw
│       └── xray/                 # opt-in VLESS+Reality inbound (personal VPN), optional relay mode
├── terraform/                    # cloud resources as code (independent root modules, one state each)
│   ├── dns/                      # Cloudflare + Porkbun DNS records (host_ips: fleet IPs live once)
│   ├── aws/                      # Lambda functions + Function URLs + IAM/EventBridge schedule
│   ├── hetzner/                  # Hetzner Cloud server (finland-01)
│   ├── timeweb/                  # Timeweb Cloud server (russia-03) + floating IPv4
│   ├── yandex/                   # Object Storage, Cloud Function, IAM/Lockbox
│   ├── yandex-budget-explorer/   # own YC folder: Cloud Functions + Lockbox + timer trigger
│   └── yandex-vk-ads-tool/       # own YC folder: Object Storage (landing bucket)
├── docs/runbooks/                # operational procedures (move-apps, break-glass)
├── geo.json                      # (gitignored) two-sided names — read by terraform AND ansible
└── scripts/                      # backups (envs, repo-private files), move-apps, pre-commit checks
```

## Roles

| Role       | What it does                                                            |
|------------|-------------------------------------------------------------------------|
| `common`   | Admin user, SSH key auth + sshd hardening, base packages, system hostname (`common_hostname`) |
| `firewall` | nftables default-drop ruleset + fail2ban jails (sshd, nginx-http-auth, nginx-honeypot on web hosts) |
| `nginx`    | Install nginx, reconcile vhosts from the apps registry, generate the geo fronts from `geo.json` |
| `tls`      | Per-zone wildcard Let's Encrypt certs via DNS-01 (Cloudflare, plus vendored hooks for Porkbun-hosted zones) — any host can serve any domain |
| `nodeapp`  | Early Node.js/pm2 runtime bootstrap; legacy host-vars apps deploy later |
| `apppm2`   | Reconcile registry PM2 apps: bootstrap desired names, delete previously managed stale names |
| `appstatic`| Registry-driven static bundles — built on fresh hosts, served by vhosts |
| `appdocker`| Registry-driven docker dependencies (containers / compose), started before apps |
| `appcron`  | Reconcile registry cron jobs — stale managed markers are removed after a move |
| `registry_manifest` | Internal helper shared by registry roles to load and persist ownership boundaries |
| `docker_runtime` | Internal Docker Engine and Compose bootstrap shared by container roles |
| `container_tls` | Internal container-readable TLS lifecycle primitives |
| `netdata`  | Install netdata, bind to localhost, child→parent streaming, Telegram/Pushover alarms |
| `wireguard`| Private WireGuard mesh (`wg0`) between fleet hosts for encrypted traffic |
| `chrony`   | Opt-in time sync: chrony replaces systemd-timesyncd (clock-stepping hypervisors) |
| `breakglass`| Emergency `rescue` user (YubiKey keys in root-owned `/etc/ssh/rescue_keys`) — survives home wipes |
| `clickhouse` | Self-hosted ClickHouse in Docker; public TLS ports (9440/8443), nightly dumps + off-site S3 |
| `mysql`    | Self-hosted MySQL 8.0 in Docker; GTID primary/replica over the mesh      |
| `k3s`      | Single-node Kubernetes on a host shared with a third party: adds narrow ufw rules instead of replacing the firewall, API reachable over the mesh only |
| `xray`     | Opt-in VLESS+Reality inbound (personal VPN): pinned binary, config validated before restart, inbound port cross-checked against the host firewall. A relay mode forwards TCP to a far host over the mesh, so the client dials a near host while the Reality handshake terminates on the far one |

## App registry & moves

Moving an app to another VPS is **one command**, with no user-visible downtime:

```sh
scripts/move-apps.py --app <name> <DST>   # one app  (--dry-run to preview)
scripts/move-apps.py <SRC> <DST>          # everything hosted on SRC
```

It flips the registry and DNS, copies the data, converges the target, smoke-tests
it, applies DNS only if the plan is update-only, waits for that to propagate, and
only then reconciles the source. Every step is idempotent and checkpointed, so a
re-run resumes where it failed. Details: [`docs/runbooks/move-apps.md`](docs/runbooks/move-apps.md).

That works because "what runs where" lives in one gitignored file —
`ansible/apps.yml` (copy from `apps.yml.example`): per app it names the host,
dirs, env files (deployed from 1Password), vhosts, processes, cron jobs and CI
deploy keys. The app roles are driven entirely by this registry, and DNS points
at hosts by name too (the `host_ips` map in `terraform/dns`), so a move is a
one-word edit in two places — the script just does it safely and in order.

## Geo registry — two-sided names

Russian ISPs shape *outbound* traffic to foreign origins: ТСПУ cuts the
connection after the first ~14 KB, so a 32 KB landing page reaches an RF visitor
truncated. The fix is to put a near address in front of the visitor and let the
border crossing happen inside the wg mesh instead. That needs three things to
agree — a Gcore zone with a geo record, an NS pair in the parent Cloudflare zone,
and a proxy vhost on the host that does *not* run the app.

All three come from **one gitignored file, `geo.json`** (copy from
`geo.json.example`), read by `terraform/gcore`, `terraform/dns` and the `nginx`
role. Adding a site is one entry:

```json
"flights.gistrec.cloud": { "origin": "finland-01", "front": "proxy" }
```

```
geo.json
  ├── terraform/gcore  → Gcore zone + A record: countries=["ru"] → rf side, default → world side
  ├── terraform/dns    → NS pair for the name in its parent Cloudflare zone
  └── ansible nginx    → proxy vhost on the far side (certs, headers, wg upstream)
```

`front: "none"` means the far side already serves the name itself — `glucose`
renders its own page from the local MySQL replica, `share` carries the very same
vhost file and reads the bucket directly. `"geo": false` marks an apex name: a
zone cannot be delegated one subdomain at a time, so `clear-transcript-bot.ru`
gets the front but no geo record until its whole zone moves to Gcore (which also
needs DNS-01 hooks for Gcore, the way `tls` already vendors them for Porkbun).

Measured 2026-10-03, worth knowing before enrolling a name: **both datacentre
paths are clean in both directions** — from Hetzner and from russia-03 every
fleet name returns in full (a 2.6 MB page in 0.7 s). The truncation lives on
consumer ISP paths, which no fleet host can observe, so enrolment is a judgement
call about who the visitors are, not something a probe decides.

## Sharing one-off files

`share.gistrec.cloud` serves files straight out of the public `gistrec-share`
bucket (`terraform/yandex/buckets.tf`). nginx only proxies, so nothing lands on a
host disk or in git — a share needs no deploy and no repository:

```sh
yc storage s3 cp ~/Downloads/report.html s3://gistrec-share/report.html
# → https://share.gistrec.cloud/report.html
```

The object name is the URL path; nested prefixes work. Content-Type comes from
the extension, which matters because the vhost sends
`X-Content-Type-Options: nosniff` — a wrong type renders as text instead of a
page. Anonymous listing is off, and objects have no expiry on purpose: a link
someone was given should not rot. Pruning is manual, `yc storage s3 rm`.

The name is delegated to Gcore for geo-routing (`terraform/gcore`): clients in
Russia get russia-03, everyone else finland-01. Both hosts carry the *same* vhost
file and reach the bucket themselves — there is no `*-rf` variant proxying to
finland-01 over the mesh, because the bucket sits in `ru-central1` and russia-03
reaches it directly. The detour would only add latency and a point of failure.

`glucose` already serves one vhost from both hosts like this, so the fleet has
three shapes, not two: it keeps a local copy of its data (the MySQL replica plus
a cron render), a share keeps no state at all, and the fronts that really do
proxy over the mesh — `pdf-v-excel`, `subtitry`, `flights`,
`clear-transcript-bot` — do so because the application runs only on finland-01.

## Quickstart

All commands are run from the repository root.

```bash
# 0. one-time setup
pipx install pre-commit && pre-commit install        # gitleaks + fmt/lint on every commit
ansible-galaxy collection install -r ansible/requirements.yml

# 1. inventory & vars — every copy below is gitignored
cp ansible/inventory/hosts.yml.example      ansible/inventory/hosts.yml
cp ansible/host_vars/web-01.yml.example     ansible/host_vars/web-01.yml
cp ansible/group_vars/all.vault.yml.example ansible/group_vars/all.vault.yml
ansible-vault encrypt ansible/group_vars/all.vault.yml

# 2. connectivity, dry-run, apply
#    If the vault is encrypted, supply its password once — either:
#      export ANSIBLE_VAULT_PASSWORD_FILE=$PWD/ansible/.vault_pass   # (gitignored)
#    or pass it per command: make check VAULT_ARGS=--ask-vault-pass
make ping
make check                                           # ansible-playbook --check --diff
make deploy

# 3. DNS as code
cp terraform/dns/terraform.tfvars.example terraform/dns/terraform.tfvars
make tf-plan                                         # then: make tf-apply
```

See the `Makefile` for the full list of targets (`make help`).

## Security model

- **No secrets in git.** Tokens, keys and real inventory are `.gitignore`d; only `*.example` templates are tracked.
- **Secrets at rest** are encrypted with `ansible-vault`. Even encrypted, the real vault stays private in this setup.
- **`gitleaks`** runs as a pre-commit hook so nothing sensitive slips into history. Two more local hooks cover what it misses, because it matches secrets by the shape of known services' tokens: `scripts/check-staged-ips.py` refuses public IPv4 literals (a host address gives away just as much while looking nothing like a token — allowed ranges in `scripts/allowed-public-ips.txt`), and `scripts/check-staged-secrets.py` refuses uuids and base64 key material (an xray client uuid *is* the inbound's password, and a private x25519 key opens it outright). Both read only the added lines of the index, via the shared `scripts/staged_diff.py`. Real values belong in the gitignored inventory and host_vars, or in the vault.
- **SSH is key-only** and root login is disabled by the `common` role. A pre-flight `assert` refuses to disable password auth unless at least one key is present in `vault_admin_ssh_keys`, so the playbook fails fast instead of locking you out.
- **Firewall is default-drop** (nftables); only SSH / 80 / 443 and explicitly listed ports are open, and fail2ban bans via nftables to match.

## Notes

Example IPs use the `203.0.113.0/24` documentation range (RFC 5737) and `example.com` — replace them with your own in the gitignored copies.
