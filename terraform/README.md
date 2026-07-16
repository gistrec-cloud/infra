# terraform — infrastructure by provider

Each subdirectory is an independent root module with its own state (independent blast radius):

| Module | Provider | Manages |
|--------|----------|---------|
| `dns/`    | Cloudflare   | DNS records for the fleet |
| `aws/`    | AWS          | Lambda functions + Function URLs |
| `yandex/` | Yandex Cloud | Object Storage, Managed MySQL, Compute, Cloud Function |
| `hetzner/`| Hetzner Cloud| Existing `finland-01` Compute server |

Run Terraform inside a module directory (`cd terraform/aws && terraform init`).

## Remote state (recommended for real use)

State holds secrets (DB passwords, access keys), so keep it private and encrypted. Use the built-in
`s3` backend pointed at Yandex Object Storage, in a **gitignored** `backend.tf` per module (the bucket
name is data, not code):

```hcl
terraform {
  backend "s3" {
    endpoints                   = { s3 = "https://storage.yandexcloud.net" }
    bucket                      = "my-tfstate-bucket"
    region                      = "ru-central1"
    key                         = "aws/terraform.tfstate"
    skip_region_validation      = true
    skip_credentials_validation = true
    skip_requesting_account_id  = true
    skip_s3_checksum            = true
  }
}
```

Backend credentials come from `AWS_ACCESS_KEY_ID` / `AWS_SECRET_ACCESS_KEY` env vars (a Yandex service
account static key). CI runs `terraform init -backend=false`, so it never touches real state.

## Adopting existing resources

Everything here already runs. Use `import { }` blocks or `terraform import` so Terraform adopts the
live resources instead of recreating them, and iterate until `terraform plan` shows no changes.
