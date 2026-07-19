# terraform/yandex — adopted Yandex Cloud footprint

One root module that **adopts the existing** Yandex Cloud resources in the `default` folder
(`b1gyyyyyyyyy-default` — real id in the gitignored `terraform.tfvars`; they were created by
hand / other tooling and imported into Terraform state — see [`../IMPORT.md`](../IMPORT.md)).
Provider `yandex-cloud/yandex ~> 0.213`.

Resources are grouped by service and declared with `for_each` over a `locals` inventory,
so each real object is one map entry rather than a hand-written block.

## What it manages (71 resources)

| File                  | Resource                             | Count | Notes |
|-----------------------|--------------------------------------|-------|-------|
| `service_accounts.tf` | `yandex_iam_service_account`         | 8     | static access keys **not** managed (secret is unrecoverable) |
| `lockbox.tf`          | `yandex_lockbox_secret`              | 3     | containers only — versions (payloads) left untouched |
| `mysql.tf`            | `yandex_mdb_mysql_cluster`           | 1     | shared `projects` cluster (`b2.medium`, network-hdd) |
| `mysql.tf`            | `yandex_mdb_mysql_database`          | 15    | one per app |
| `mysql.tf`            | `yandex_mdb_mysql_user`              | 18    | `ignore_changes = [password]` — apply never rotates prod passwords |
| `buckets.tf`          | `yandex_storage_bucket`              | 5     | `ignore_changes = [lifecycle_rule, logging]` (managed over S3) |
| `compute.tf`          | `yandex_compute_instance`            | 2     | `ignore_changes = [metadata]` (huge + console-mutated) |
| `iam.tf`              | `yandex_resourcemanager_folder_iam_member` | 18 | **additive** grants (14 SA + 4 personal `monitoring.viewer`) |
| `functions.tf`        | `yandex_function`                    | 1     | `realm-status` — zip built from source (`realm_status_source_dir`); TF owns deploy |

**Not adopted:** `upload-photo-to-recepter-s3` (its source repo isn't on disk — see
[`functions.tf`](functions.tf) for the recipe); the VPC network / subnets (auto `default`)
and auto DNS zones are referenced by id, not managed; static access keys and Lockbox secret
*versions* are left outside Terraform on purpose.

> **Function deploy**: `realm-status` is deployed by Terraform (`data.archive_file` builds the
> zip → `yandex_function` publishes a version). This replaces the `yc function version create`
> step in the app repo's `deploy.sh`. `terraform plan/apply` needs `realm_status_source_dir` to
> point at the source checkout.

## Usage

```bash
export YC_TOKEN="$(yc config get token)"           # or YC_SERVICE_ACCOUNT_KEY_FILE=key.json
cp terraform.tfvars.example terraform.tfvars        # gitignored — fill real ids
terraform init && terraform plan                    # expect: No changes
```

## The invariant

`terraform plan` **must** report `No changes`. Any `~`/`-/+` means the config drifted from
reality — fix the config (or the `locals` inventory), never blindly apply against production.

State carries no plaintext secrets in this adoption (no passwords, no static keys, no Lockbox
payloads were imported), but still keep it in a **private, encrypted remote backend** and never
commit it. See the top-level [`../README.md`](../README.md).
