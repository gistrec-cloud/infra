# terraform — infrastructure by provider

Each subdirectory is an independent root module with its own state (independent blast radius):

| Module                    | Provider             | Manages |
|---------------------------|----------------------|---------|
| `dns/`                    | Cloudflare + Porkbun | DNS records for the fleet |
| `gcore/`                  | Gcore                | `glucose.gistrec.cloud` — the one subdomain delegated off Cloudflare, for geo-routing |
| `aws/`                    | AWS                  | Lambda functions + Function URLs, per-function IAM roles, hourly EventBridge Scheduler timer |
| `yandex/`                 | Yandex Cloud         | `default` folder: Object Storage, IAM (service accounts + role grants), Lockbox, Cloud Function + timer trigger |
| `hetzner/`                | Hetzner Cloud        | Existing `finland-01` cloud server |
| `timeweb/`                | Timeweb Cloud        | `russia-03` server + its SSH key + its floating IPv4 |
| `yandex-budget-explorer/` | Yandex Cloud         | `budget-explorer` folder: Cloud Functions + timer trigger, Lockbox secrets, SA + IAM grants |
| `yandex-vk-ads-tool/`     | Yandex Cloud         | `vk-ads-tool` folder: the `vk-ads-tool-landing` bucket |

Nothing runs on Yandex compute or managed databases any more: the managed MySQL cluster was destroyed
2026-07-21 (replaced by the self-hosted `mysql` role on finland-01), the last VM 2026-08-19 —
`yandex/mysql.tf` and the empty instance map in `yandex/compute.tf` are tombstones.

Run Terraform inside a module directory (`cd terraform/aws && terraform init`).

## Remote state (recommended for real use)

State holds secrets (the `russia-03` root password Timeweb hands back, function/Lambda environment
variables), so keep it private and encrypted. Use the built-in `s3` backend pointed at Yandex Object
Storage, in a per-module `backend.tf` — `terraform/*/backend.tf` is gitignored (the bucket name is
data, not code):

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

Almost everything here predates its module (`timeweb/` is the exception — it created `russia-03`
itself). Use `import { }` blocks or `terraform import` so Terraform adopts the live resources instead
of recreating them, and iterate until `terraform plan` shows no changes. Per-provider recipes:
[`IMPORT.md`](IMPORT.md).
