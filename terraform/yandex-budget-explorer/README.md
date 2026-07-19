# terraform/yandex-budget-explorer — budget-explorer folder

Root module for the Yandex Cloud **`budget-explorer`** folder (`b1gyyyyyyyyyy-budget` — real
id in the gitignored `terraform.tfvars`), separate from `terraform/yandex` (the `default`
folder) with its own provider `folder_id` and state. All resources but the IAM grants were
adopted via import — see [`../IMPORT.md`](../IMPORT.md); the grants are TF-created,
per-resource replacements for the unmanaged folder-wide roles the SA runs on today
(dropping those is a manual step).

## What it manages (16 resources)

| File                  | Resource                           | Count | Notes |
|-----------------------|------------------------------------|-------|-------|
| `service_accounts.tf` | `yandex_iam_service_account`       | 1     | `budget-explorer` |
| `lockbox.tf`          | `yandex_lockbox_secret`            | 6     | containers only (payloads untouched) |
| `lockbox.tf`          | `yandex_lockbox_secret_iam_member` | 5     | payloadViewer for the SA — only the 5 secrets the functions mount |
| `triggers.tf`         | `yandex_function_trigger`          | 1     | timer, fires `sync-transactions` every 6h |
| `functions.tf`        | `yandex_function`                  | 2     | `sync-transactions`, `telegram-bot` — TF owns deploy |
| `functions.tf`        | `yandex_function_iam_binding`      | 1     | invoker on `sync-transactions` for the trigger SA — see the never-extend note in `functions.tf` |

The `budget-explorer` **MySQL database + user** live in the shared `projects` cluster in the
`default` folder and are managed by `terraform/yandex`, not here.

## Function deploy

Both functions are built from one source checkout (`functions_source_dir`) via
`data.archive_file` and published by Terraform — this replaces the `yc function version create`
step in the app repo's `deploy.sh` (its VPS bot deploy is unrelated and stays). `telegram-bot`
appears dormant (no trigger; the live bot runs via pm2 on the VPS).

## Usage

```bash
export YC_TOKEN="$(yc config get token)"
cp terraform.tfvars.example terraform.tfvars    # gitignored — fill ids + functions_source_dir
terraform init && terraform plan                 # expect: No changes
```
