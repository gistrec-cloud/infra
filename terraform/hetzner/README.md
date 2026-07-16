# terraform/hetzner — Hetzner Cloud

Adopts the existing `finland-01` server into Terraform. This is an independent
root module with its own state and blast radius.

## Existing server

| name | server ID | location | IPv4 |
|---|---:|---|---|
| `finland-01` | `151586283` | `hel1` (`hel1-dc2`) | `62.238.12.36` |

## Authentication

Create a Hetzner Cloud API token for the project and expose it without writing
the value to the repository:

```bash
export HCLOUD_TOKEN="$(op read 'op://Gistrec Cloud/hetzner-cloud/credential')"
```

The item/field path above is the expected convention; adjust it if the
1Password item uses another name. The provider reads `HCLOUD_TOKEN` directly.

## Safe adoption

The server already exists. Never run a normal `apply` before the generated
configuration has been reconciled with the live resource.

```bash
cd terraform/hetzner
terraform init

cat > import.tf <<'EOF'
import {
  to = hcloud_server.finland_01
  id = "151586283"
}
EOF

terraform plan -generate-config-out=generated.tf
```

Both `import.tf` and `generated.tf` are gitignored. Review the generated server
resource, move the intentional settings into a tracked `server.tf`, and add:

```hcl
lifecycle {
  prevent_destroy = true
  ignore_changes  = [ssh_keys, user_data]
}
```

`ssh_keys` and cloud-init data are creation-time bootstrap inputs; changing the
former can propose server replacement. Iterate until the plan is strictly:

```text
1 to import, 0 to add, 0 to change, 0 to destroy
```

Only then apply the import and verify the next plan says `No changes`.

Provider authentication and server import behavior are documented in the
[hcloud provider](https://registry.terraform.io/providers/hetznercloud/hcloud/latest/docs)
and [`hcloud_server` resource](https://registry.terraform.io/providers/hetznercloud/hcloud/latest/docs/resources/server).
