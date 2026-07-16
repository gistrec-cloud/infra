# infra

[![CI](https://github.com/gistrec-cloud/infra/actions/workflows/ci.yml/badge.svg)](https://github.com/gistrec-cloud/infra/actions/workflows/ci.yml)

Infrastructure as code for the **gistrec-cloud** fleet.

- **Ansible** configures what lives *inside* the servers — base hardening, firewall, nginx, Node/pm2 apps, monitoring.
- **Terraform** manages cloud resources — DNS (Cloudflare), AWS Lambda, and Yandex Cloud (Object Storage, Managed MySQL, Compute, Cloud Functions).

The repository is deliberately split into **code** (public, here) and **live data** (private, never committed): real inventory, IPs, tokens and state stay out of git. Everything you see here uses placeholders — copy the `*.example` files, fill them locally, and they are already covered by `.gitignore`.

## Architecture

```
   registrar (reg.ru / godaddy)          ┌──────────────┐
   nameservers delegated to  ──────────► │  Cloudflare  │   DNS as code
                                         │     DNS      │   (terraform/)
                                         └──────┬───────┘
                                                │  A / CNAME
                    ┌───────────────────────────┼─────────────────────────────┐
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
                        │   Managed MySQL   │   Yandex Cloud (terraform/yandex) — planned move
                        │  (Yandex Cloud)   │   to the self-hosted mysql role (Docker,
                        └───────────────────┘   GTID primary/replica over the wg0 mesh)
```

## Layout

```
infra/
├── ansible/
│   ├── ansible.cfg
│   ├── requirements.yml          # Galaxy collections
│   ├── site.yml                  # wires roles to host groups
│   ├── inventory/hosts.yml       # (gitignored) real hosts — copy from .example
│   ├── group_vars/               # non-secret defaults + vault for secrets
│   ├── host_vars/                # per-host: which apps/sites run where
│   └── roles/
│       ├── common/               # users, SSH hardening, base packages
│       ├── firewall/             # nftables + fail2ban
│       ├── nginx/                # reverse proxy + Let's Encrypt
│       ├── nodeapp/              # Node.js + pm2 deploy
│       ├── netdata/              # monitoring agent
│       ├── wireguard/            # private encrypted mesh between fleet hosts
│       └── mysql/                # self-hosted MySQL (Docker), primary/replica
└── terraform/                    # cloud resources as code (one root module per provider)
    ├── dns/                      # Cloudflare DNS records
    ├── aws/                      # Lambda functions + Function URLs
    └── yandex/                   # Object Storage, Managed MySQL, Compute, Cloud Function
```

## Roles

| Role       | What it does                                                            |
|------------|-------------------------------------------------------------------------|
| `common`   | Admin user, SSH key auth + sshd hardening, base packages, timezone      |
| `firewall` | nftables default-drop ruleset + fail2ban jails (sshd, nginx-http-auth)  |
| `nginx`    | Install nginx, deploy vhosts, obtain TLS certs via certbot              |
| `nodeapp`  | Node.js (NodeSource) + pm2, deploy apps, persist across reboot          |
| `netdata`  | Install netdata, bind to localhost, Telegram alert when a pm2 app dies  |
| `wireguard`| Private WireGuard mesh (`wg0`) between fleet hosts for encrypted traffic |
| `mysql`    | Self-hosted MySQL 8.0 in Docker; GTID primary/replica over the mesh      |

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
- **`gitleaks`** runs as a pre-commit hook so nothing sensitive slips into history.
- **SSH is key-only** and root login is disabled by the `common` role. A pre-flight `assert` refuses to disable password auth unless at least one key is present in `vault_admin_ssh_keys`, so the playbook fails fast instead of locking you out.
- **Firewall is default-drop** (nftables); only SSH / 80 / 443 and explicitly listed ports are open, and fail2ban bans via nftables to match.

## Notes

Example IPs use the `203.0.113.0/24` documentation range (RFC 5737) and `example.com` — replace them with your own in the gitignored copies.
