# terraform/yandex — adopted Yandex Cloud footprint

One root module that **adopts the existing** Yandex Cloud resources in the `default` folder
(`b1gyyyyyyyyy-default` — real id in the gitignored `terraform.tfvars`; they were created by
hand / other tooling and imported into Terraform state — see [`../IMPORT.md`](../IMPORT.md)).
Providers `yandex-cloud/yandex ~> 0.213` and `hashicorp/archive ~> 2.4` (the function zip).

Resources are grouped by service and declared with `for_each` over a `locals` inventory,
so each real object is one map entry rather than a hand-written block. Anything added since the
adoption (glucose-bot's SA + bucket, the `mysql-backup` uploader SA, the dedicated `realm-status`
SA with its Lockbox and invoker grants) is created by Terraform outright.

## What it manages (41 resources)

| File                  | Resource                                   | Count | Notes |
|-----------------------|--------------------------------------------|-------|-------|
| `service_accounts.tf` | `yandex_iam_service_account`               | 11    | static access keys **not** managed (secret is unrecoverable) |
| `lockbox.tf`          | `yandex_lockbox_secret`                    | 3     | containers only — versions (payloads) left untouched |
| `lockbox.tf`          | `yandex_lockbox_secret_iam_member`         | 3     | per-secret `lockbox.payloadViewer` for the `realm-status` SA |
| `buckets.tf`          | `yandex_storage_bucket`                    | 6     | `ignore_changes = [lifecycle_rule, logging]` (managed over S3) |
| `iam.tf`              | `yandex_resourcemanager_folder_iam_member` | 14    | **additive** grants (10 SA + 4 personal `monitoring.viewer`) |
| `iam.tf`              | `yandex_storage_bucket_iam_binding`        | 1     | **authoritative** — `storage.editor` for glucose-bot, on its bucket only |
| `functions.tf`        | `yandex_function`                          | 1     | `realm-status` — zip built from source (`realm_status_source_dir`); TF owns deploy |
| `functions.tf`        | `yandex_function_iam_binding`              | 1     | authoritative invoker — the `realm-status` SA and nothing else |
| `triggers.tf`         | `yandex_function_trigger`                  | 1     | `realmctl-each-5-mins` timer (`*/5 * ? * * *`) |

Plus one `data.archive_file` (the function zip) — a data source, outside that count.

**Retired, kept as tombstones:** the shared managed MySQL cluster `projects` was destroyed
2026-07-21 once every database had moved to the self-hosted MySQL 8.0 primary on finland-01 —
[`mysql.tf`](mysql.tf) is now just that note, and the database/user registry lives in
`ansible/group_vars/db.yml` (gitignored; `db.yml.example` in git). Both Compute instances went
the same way (russia-02 2026-07-21, russia-01 2026-08-19), so [`compute.tf`](compute.tf) still
declares the resource but iterates an empty `locals.instances`: no VM runs in Yandex Cloud any
more.

**Not adopted:** `upload-photo-to-recepter-s3` (its source repo isn't on disk — see
[`functions.tf`](functions.tf) for the recipe); the VPC network / subnets (auto `default`) come
in by id as variables and the auto DNS zones aren't touched at all; static access keys and
Lockbox secret *versions* are left outside Terraform on purpose.

> **Function deploy**: `realm-status` is deployed by Terraform (`data.archive_file` builds the
> zip → `yandex_function` publishes a version). This replaces the `yc serverless function
> version create` step in the app repo's `deploy.sh`. `terraform plan/apply` needs
> `realm_status_source_dir` to point at the source checkout.

## Usage

```bash
export YC_TOKEN="$(yc config get token)"            # or YC_SERVICE_ACCOUNT_KEY_FILE=key.json
cp terraform.tfvars.example terraform.tfvars        # gitignored — fill real ids
terraform init && terraform plan                    # expect: No changes
```

## The invariant

`terraform plan` **must** report `No changes`. Any `~`/`-/+` means the config drifted from
reality — fix the config (or the `locals` inventory), never blindly apply against production.

State carries no plaintext secrets in this adoption (no passwords, no static keys, no Lockbox
payloads were imported), but still keep it in a **private, encrypted remote backend** and never
commit it. See the top-level [`../README.md`](../README.md).
