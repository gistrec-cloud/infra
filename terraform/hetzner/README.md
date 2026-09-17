# terraform/hetzner — Hetzner Cloud

Manages `finland-01`, the fleet's only Hetzner server — adopted from the cloud,
not created here. An independent root module with its own state and blast
radius; provider `hetznercloud/hcloud ~> 1.66`.

## Existing server

| name | server ID | location | IPv4 |
|---|---:|---|---|
| `finland-01` | `151586283` | `hel1` (`hel1-dc2`) | `62.238.12.36` |

## Authentication

The project API token lives in 1Password; the gitignored root `.envrc` exports
it via direnv:

```bash
export HCLOUD_TOKEN="$(op read 'op://Gistrec Cloud/hetzner-token/password')"
```

The provider reads `HCLOUD_TOKEN` directly — the module takes no variables, so
there is no `terraform.tfvars`.

## Adoption — done

The server was imported, not created: it has been in state since `a7e9758`
(2026-07-16), the tracked `server.tf` is its configuration, and `terraform plan`
reports `No changes`. Anything else means the config drifted from the live
server — fix the config, never apply blindly.

`finland-01` is protected twice over: `delete_protection` / `rebuild_protection`
on the Hetzner side (added in `7c66129`; these also block deletion from the
console) and `prevent_destroy` on the Terraform side. `ssh_keys` and `user_data`
sit under `ignore_changes` — they were creation-time bootstrap inputs only
(Ansible owns the in-guest SSH configuration now) and changing them can propose
server replacement. Import the *next* Hetzner resource that turns up the same
way — the generic `import {}` recipe is in [`../IMPORT.md`](../IMPORT.md).

Provider authentication and server import behavior are documented in the
[hcloud provider](https://registry.terraform.io/providers/hetznercloud/hcloud/latest/docs)
and [`hcloud_server` resource](https://registry.terraform.io/providers/hetznercloud/hcloud/latest/docs/resources/server).
