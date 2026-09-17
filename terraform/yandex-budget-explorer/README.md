# terraform/yandex-budget-explorer — budget-explorer folder

Root module for the Yandex Cloud **`budget-explorer`** folder (`b1gyyyyyyyyyy-budget` — real
id in the gitignored `terraform.tfvars`), separate from `terraform/yandex` (the `default`
folder) with its own provider `folder_id` and state. All resources but the IAM grants and the
two `anthropic-relay-*` secrets were adopted via import — see [`../IMPORT.md`](../IMPORT.md);
the grants are TF-created, per-resource replacements for the unmanaged folder-wide roles the
SA runs on today (dropping those is a manual step).

## What it manages (20 resources)

| File                  | Resource                           | Count | Notes |
|-----------------------|------------------------------------|-------|-------|
| `service_accounts.tf` | `yandex_iam_service_account`       | 1     | `budget-explorer` |
| `lockbox.tf`          | `yandex_lockbox_secret`            | 8     | containers only (payloads untouched) |
| `lockbox.tf`          | `yandex_lockbox_secret_iam_member` | 7     | payloadViewer for the SA — only the 7 secrets the functions mount (nothing mounts `webhook-secret`) |
| `triggers.tf`         | `yandex_function_trigger`          | 1     | timer, fires `sync-transactions` every 6h |
| `functions.tf`        | `yandex_function`                  | 2     | `sync-transactions`, `telegram-bot` — TF owns deploy |
| `functions.tf`        | `yandex_function_iam_binding`      | 1     | invoker on `sync-transactions` for the trigger SA — see the never-extend note in `functions.tf` |

The `budget-explorer` **MySQL database + user** live on the self-hosted MySQL primary
`finland-01` (`public.mysql.gistrec.cloud` — see `function_env` in `functions.tf`); the shared
managed `projects` cluster in the `default` folder was destroyed 2026-07-21. The database/user
registry is `ansible/group_vars/db.yml` (gitignored; `db.yml.example` is in git), not Terraform.

## Function deploy

Both functions are built from one source checkout (`functions_source_dir`) via
`data.archive_file` and published by Terraform — this replaces the `yc function version create`
step in the app repo's `deploy.sh` (its VPS bot deploy is unrelated and stays). `telegram-bot`
appears dormant (no trigger; the live bot runs via pm2 on finland-01).

## Usage

```bash
export YC_TOKEN="$(yc config get token)"
cp terraform.tfvars.example terraform.tfvars    # gitignored — fill ids + functions_source_dir
terraform init && terraform plan                # expect: No changes
```
