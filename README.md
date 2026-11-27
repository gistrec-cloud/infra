# infra

[![CI](https://github.com/gistrec-cloud/infra/actions/workflows/ci.yml/badge.svg)](https://github.com/gistrec-cloud/infra/actions/workflows/ci.yml)

Infrastructure as code for the gistrec-cloud fleet.

- Ansible configures what lives *inside* the servers: base hardening, firewall, nginx, registry-driven apps (pm2 / static / docker / cron), self-hosted databases, monitoring.
- Terraform manages cloud resources: DNS (Cloudflare + Porkbun, geo-routed names on Gcore), Gcore Object Storage, AWS Lambda relays, the Hetzner and Timeweb servers, a managed Apache Kafka cluster on Confluent Cloud, and Yandex Cloud (Object Storage, Cloud Functions, IAM/Lockbox).

This public repository holds only code. Live data (real inventory, IPs, tokens and state) is private and never committed. Everything here uses placeholders. Copy the `*.example` files and fill them locally; the copies are already covered by `.gitignore`.

Run `brew install pre-commit && make hooks` after cloning. Nothing in `.pre-commit-config.yaml` runs without that binary, and nothing tells you it is missing. Alongside gitleaks and the linters it installs a check that refuses any public IPv4 in a tracked file: `.gitignore` protects whole files, this catches the address pasted into a comment or a README.

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

              ┌───────────────────┐
              │   Apache Kafka    │   terraform/confluent — managed cluster on Confluent Cloud
              │ (Confluent Cloud) │   (Basic, GCP europe-north1 — next door to finland-01).
              └─────────┬─────────┘   Clients connect over SASL_SSL; sized to stay inside the
                        │             free first eCKU (30 partitions, 20 connections).
                        │  market-data-collector (pm2, finland-01) produces Binance + Kraken
                        └► trades to marketdata.*.trades; ClickHouse on finland-01 consumes
                           them with its Kafka engine into marketdata.trades.
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
│       ├── redis/                # opt-in local Redis cache on loopback (unused for now)
│       ├── s3mirror/             # opt-in timer: Yandex Object Storage → Gcore mirror, s3-rclone
│       └── xray/                 # opt-in VLESS+Reality inbound (personal VPN), optional relay mode
├── terraform/                    # cloud resources as code (independent root modules, one state each)
│   ├── dns/                      # Cloudflare + Porkbun DNS records (host_ips: fleet IPs live once)
│   ├── aws/                      # Lambda relays (openai, anthropic, telegram, github) + yandex-rating-counter
│   ├── confluent/                # Confluent Cloud: Kafka cluster finland-01 (Basic, GCP europe-north1)
│   ├── gcore/                    # geo-routed DNS zones (from geo.json) + Object Storage buckets
│   ├── hetzner/                  # Hetzner Cloud server (finland-01)
│   ├── timeweb/                  # Timeweb Cloud server (russia-03) + floating IPv4
│   ├── yandex/                   # Object Storage, Cloud Function, IAM/Lockbox
│   ├── yandex-budget-explorer/   # own YC folder: Cloud Functions + Lockbox + timer trigger
│   └── yandex-vk-ads-tool/       # own YC folder: Object Storage (landing bucket)
├── docs/runbooks/                # operational procedures (move-apps, break-glass, s3-mirror)
├── geo.json                      # (gitignored) two-sided names — read by terraform AND ansible
└── scripts/                      # backups (envs, repo-private files), move-apps, S3 mirror tools, pre-commit checks, local secrets (agents, dev .env)
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
| `netdata`  | Install netdata, bind to localhost, child→parent streaming, Telegram/Pushover alarms. A Telegram alert is one message per episode, edited on CLEAR (`alarm-telegram.py`); the `unnotified-alarms` timer sends CRITICALs netdata never notified about; `status-snapshot` writes the data for `gistrec.cloud/status` and the private `stats.gistrec.cloud/status` every minute; downtime alerts also go to a project's own chat (`alert_chats`). `scripts/mute-alerts.sh` mutes all notifications fleet-wide for planned work. Conventions: [role README](ansible/roles/netdata/README.md) |
| `wireguard`| Private WireGuard mesh (`wg0`) between fleet hosts for encrypted traffic |
| `chrony`   | Opt-in time sync: chrony replaces systemd-timesyncd (clock-stepping hypervisors) |
| `breakglass`| Emergency `rescue` user (YubiKey keys in root-owned `/etc/ssh/rescue_keys`) — survives home wipes |
| `clickhouse` | Self-hosted ClickHouse in Docker; public TLS ports (9440/8443), nightly dumps + off-site S3 |
| `mysql`    | Self-hosted MySQL 8.0 in Docker; GTID primary/replica over the mesh      |
| `k3s`      | Single-node Kubernetes on a host shared with a third party: adds narrow ufw rules instead of replacing the firewall, API reachable over the mesh only |
| `redis`    | Opt-in (`redis_managed`): local Redis cache from apt, loopback only, cache only (no persistence, no replica — data lives in MySQL). Not enabled on any host yet. [Role README](ansible/roles/redis/README.md) |
| `s3mirror` | Opt-in (`s3mirror_managed`, finland-01): rclone timer mirroring Yandex Object Storage buckets to Gcore; installs the `s3-rclone` wrapper used below. Runbook: [`docs/runbooks/s3-mirror.md`](docs/runbooks/s3-mirror.md) |
| `xray`     | Opt-in VLESS+Reality inbound (personal VPN): pinned binary, config validated before restart, inbound port cross-checked against the host firewall. A relay mode forwards TCP to a far host over the mesh, so the client dials a near host while the Reality handshake terminates on the far one |

## App registry & moves

Moving an app to another VPS is one command, with no user-visible downtime:

```sh
scripts/move-apps.py --app <name> <DST>   # one app  (--dry-run to preview)
scripts/move-apps.py <SRC> <DST>          # everything hosted on SRC
```

It flips the registry and DNS, copies the data, converges the target, smoke-tests
it, applies DNS only if the plan is update-only, waits for that to propagate, and
only then reconciles the source. Every step is idempotent and checkpointed, so a
re-run resumes where it failed. Details: [`docs/runbooks/move-apps.md`](docs/runbooks/move-apps.md).

"What runs where" lives in one gitignored file,
`ansible/apps.yml` (copy from `apps.yml.example`): per app it names the host,
dirs, env files (deployed from 1Password), vhosts, processes, cron jobs and CI
deploy keys. The app roles are driven entirely by this registry, and DNS points
at hosts by name too (the `host_ips` map in `terraform/dns`), so a move is a
one-word edit in two places. The script makes both edits in order, with the checks above.

### Alerts in a project's chat

All alarms go to the owner's Telegram chat. A project can also get its own
downtime alerts in its development chat: add @GistrecCloudBot to the chat, send
`/id` there, put the answer into the app's `alert_chats` in `apps.yml`
(`alert_chats: ["-1001234567890"]`, or `"chat:thread"` for a forum topic), and
re-run the netdata role on the parent (`--tags netdata`); `/alerts` in the chat
then lists what it will receive. The chat gets only CRITICAL and recovery of
the downtime alarms (pm2 process down, the `*_health_down` probe, the
project's required alarms), worded for the team, with no node names, charts
or netdata links; metric alarms stay with the owner. The commands live in the
bot's own app (GistrecCloudBot), which reads `alert-feed.json` from the parent
over the mesh. Details: [netdata role README](ansible/roles/netdata/README.md#чаты-проектов).

## Geo registry: two-sided names

Russian ISPs shape *outbound* traffic to foreign origins: ТСПУ cuts the
connection after the first ~14 KB, so a 32 KB landing page reaches an RF visitor
truncated. The fix is to put a near address in front of the visitor and let the
border crossing happen inside the wg mesh. Three things have to
agree: a Gcore zone with a geo record, an NS pair in the parent Cloudflare zone,
and a proxy vhost on the host that does *not* run the app.

All three come from one gitignored file, `geo.json` (copy from
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

`front: "none"` means the far side already serves the name itself: `share`
carries the very same vhost file and reads the bucket directly, `meow` keeps its
own copy of one static page (its `deploy.sh` uploads to both hosts). `"geo": false` marks an apex name: a
zone cannot be delegated one subdomain at a time, so `clear-transcript-bot.ru`
gets the front but no geo record until its whole zone moves to Gcore (which also
needs DNS-01 hooks for Gcore, the way `tls` already vendors them for Porkbun).

Before enrolling a name, note the 2026-10-03 measurement: both datacentre
paths are clean in both directions. From Hetzner and from russia-03 every
fleet name returns in full (a 2.6 MB page in 0.7 s). The truncation lives on
consumer ISP paths, which no fleet host can observe, so whether to enrol a name
depends on who its visitors are. A probe from the fleet can't decide it.

## Sharing one-off files

`share.gistrec.cloud` serves files straight out of the public `gistrec-share`
bucket (`terraform/gcore/storage.tf`, Gcore since 2026-10-11). nginx only proxies, so nothing lands on a
host disk or in git, and a share needs no deploy and no repository:

```sh
scp ~/Downloads/report.html finland-01:/tmp/ && ssh finland-01 sudo s3-rclone copyto /tmp/report.html gc:gistrec-share/report.html
# → https://share.gistrec.cloud/report.html
```

The object name is the URL path; nested prefixes work. Content-Type comes from
the extension, which matters because the vhost sends
`X-Content-Type-Options: nosniff`: a wrong type renders as text instead of a
page. Anonymous listing is off, and objects have no expiry on purpose: a link
someone was given should not rot. Pruning is manual:
`ssh finland-01 sudo s3-rclone deletefile gc:gistrec-share/<file>`.

The name is delegated to Gcore for geo-routing (`terraform/gcore`): clients in
Russia get russia-03, everyone else finland-01. Both hosts carry the *same* vhost
file and reach the bucket themselves. There is no `*-rf` variant proxying to
finland-01 over the mesh, because the bucket (Gcore `s-ed1`, Luxembourg) is
reachable from russia-03 directly. A detour would only add latency and one more point of failure.

`meow` also serves one vhost from both hosts, so the fleet has three
shapes: `meow` keeps a local copy of a static page on each host, a share
keeps no state at all, and the fronts that do proxy over the mesh
(`glucose`, `pdf-v-excel`, `subtitry`, `flights`, `govorit`,
`clear-transcript-bot`) do so because the application runs only on finland-01
(`usage` the other way round: it runs only on russia-03).

## Local secrets: AI agents and dev `.env`

Coding agents (omp, Claude Code) get MCP credentials from a separate 1Password
vault, **Agent Access**, through a read-only service account whose token sits in
the macOS Keychain (`op-agent-access`). No Touch ID prompt, and the account can
read nothing outside that vault.

```sh
scripts/setup-agent-access.sh   # one-off: vault + service account + Keychain item
scripts/agent-secret 'op://Agent Access/<item>/<field>'   # omp MCP env: "!…/agent-secret '…'"
scripts/agent-op-run <server command…>                    # Claude MCP: env with op:// refs resolved
```

Local `.env` files keep secrets only as `op://` references to the `Gistrec Cloud`
vault, so a leaked checkout or a curious agent gets references, not values. Run
the app with `op run --env-file .env -- <command>`. None of these scripts prints a value.

```sh
scripts/env-to-op.py <project-dir> [.env]           # dry run: which keys move
scripts/env-to-op.py <project-dir> [.env] --apply   # backup doc + item, verify, rewrite
scripts/env-compare.py <file>...                    # local prod copy vs "dotenv <app>" docs (key names only)
scripts/env-compare.py --delete-identical <file>... # drop copies that 1Password already has
scripts/env-pull.py "dotenv <app>" <file> [--keep=MYSQL_HOST]  # refresh a local prod copy, keep local overrides
```

## Bug-hunt: advisory status and VM dispatcher

A daily launchd job (`~/Library/LaunchAgents/cloud.gistrec.bughunt-status.plist`,
09:30, log `~/Library/Logs/bughunt-status.log`) runs `scripts/hunt-status-daily`:

1. `~/Projects/bug-hunt/.hunt/bin/hunt-status` makes read-only `gh api` calls for
   every GHSA I filed, stores state and events in `.hunt/hunt.db`, rewrites
   `.hunt/ACTIONS.md` ("needs you" / "for the agent") and queues one Telegram
   message in `.hunt/status/outbox/`. It runs with no secret in its environment.
2. `scripts/hunt-tg-notify` sends the queue through @GistrecCloudBot to the
   bug-hunt topic of the Gistrec Cloud chat (`-1004479872750:375`). Only this
   step gets the bot token: `agent-op-run` resolves
   `op://Agent Access/telegram-GistrecCloudBot/credential`. It only reads text files from
   the bug-hunt workspace, never runs code from there. Sending is one-way
   (`sendMessage`), so it does not clash with the bot app's own `getUpdates`.

Before the sweep the job runs `.hunt/bin/hunt-file-queue`: reports the user has
already approved (`.hunt/queue/<slug>.json` with a `not_before` date) are filed
through `gh api`, and the result goes to the same Telegram topic. It exists for
GitHub's daily limit on private vulnerability reports: a report refused with
that 403 stays queued for the next day.

```sh
launchctl load ~/Library/LaunchAgents/cloud.gistrec.bughunt-status.plist   # enable
launchctl start cloud.gistrec.bughunt-status                                # run now
```

Untrusted code from audited projects runs only on the VMs, through a
forced-command SSH key: `~/.ssh/hunt_dispatch_ed25519` is in each VM's
`authorized_keys` as `restrict,command="…/.local/share/hunt/hunt_dispatch.py"`
(source and per-host limits: `~/Projects/bug-hunt/.hunt/vm/`). The
`hunt-<vm>` aliases in `~/.ssh/config` (block installed by
`.hunt/vm/install-ssh-alias.sh`) use only that key and no agent. They multiplex
only among themselves (`ControlPath ~/.ssh/cm-hunt-%n`, `ControlPersist 10m`),
never over the full-access connections; without it parallel agents hit sshd's
per-source limits. The forced command applies to every session on the master.
The dispatcher runs labelled (`bughunt=1`) containers with
no network, uid 1000, no capabilities and resource limits, and never touches
unlabelled containers, so it cannot reach the host's own services. Ansible sets
keys with `exclusive: false`, so a playbook run keeps the line; remove it by hand
(backup `~/.ssh/authorized_keys.bak-hunt` on each VM) to revoke.

## omp command guard

The guard that decides which agent commands run without asking (hooks, decision logic,
the Agent Privilege Manager Touch ID helper) lives in its own repository,
[gistrec/agent-guard](https://github.com/gistrec/agent-guard).

What stays here is the server-side limit. Repositories where a merge to the default branch
deploys, plus this one, have the ruleset `default branch: PR only`: no direct push, force
push or deletion, and no bypass, admins included. It is set on `gistrec-cloud/infra`,
`gistrec/usage-beacon`, `gistrec/aleksandravoo` and `gistrec/jobs`, so changes land through
a PR. The ruleset does not stop a merge or a ruleset change made with my `gh` token; only
the client-side guard asks about those.

## Quickstart

All commands are run from the repository root.

```bash
# 0. one-time setup
brew install pre-commit && make hooks                # gitleaks + fmt/lint + IP/secret checks on every commit
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

- No secrets in git. Tokens, keys and real inventory are `.gitignore`d; only `*.example` templates are tracked.
- Secrets at rest are encrypted with `ansible-vault`. Even encrypted, the real vault stays private in this setup.
- `gitleaks` runs as a pre-commit hook so nothing sensitive slips into history. Two more local hooks cover what it misses, because it matches secrets by the shape of known services' tokens: `scripts/check-staged-ips.py` refuses public IPv4 literals (a host address gives away just as much while looking nothing like a token; allowed ranges are in `scripts/allowed-public-ips.txt`), and `scripts/check-staged-secrets.py` refuses uuids and base64 key material (an xray client uuid *is* the inbound's password, and a private x25519 key opens it outright). Both read only the added lines of the index, via the shared `scripts/staged_diff.py`. Real values belong in the gitignored inventory and host_vars, or in the vault.
- SSH is key-only and root login is disabled by the `common` role. A pre-flight `assert` refuses to disable password auth unless at least one key is present in `vault_admin_ssh_keys`, so the playbook fails fast instead of locking you out.
- The firewall is default-drop (nftables); only SSH / 80 / 443 and explicitly listed ports are open, and fail2ban bans via nftables to match.

## Notes

Example IPs use the `203.0.113.0/24` documentation range (RFC 5737) and `example.com`; replace them with your own in the gitignored copies.
