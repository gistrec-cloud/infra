# terraform/yandex — Object Storage, Managed MySQL, Compute, Cloud Function

One root module for the Yandex Cloud footprint. Provider `yandex-cloud/yandex ~> 0.213`.

## Usage

```bash
export YC_TOKEN=...                                # or: export YC_SERVICE_ACCOUNT_KEY_FILE=key.json
cp terraform.tfvars.example terraform.tfvars       # gitignored
terraform init && terraform plan
```

## What it manages

- **Object Storage** — a bucket plus a dedicated service account and static access key (`storage.editor`).
- **Managed MySQL** — cluster + database + user. The password is generated with `random_password`
  and mirrored into **Lockbox** (`yandex_lockbox_secret`), so it is never typed into a file.
- **Compute Cloud** — one instance from the latest `ubuntu-2204-lts` image.
- **Cloud Function** — deployed from a zip provided at apply time.

The VPC network and subnet are referenced by id (`network_id` / `subnet_id`) — they already exist.

## State carries secrets

The MySQL password, the bucket's secret key and the Lockbox value all land in Terraform state in
plaintext. Keep state in a **private, encrypted remote backend** (Yandex Object Storage `s3` backend) —
never local for real use, never committed. See the top-level `terraform/README.md`.

## Adopting existing resources

Import instead of recreating — e.g. the MySQL cluster (import id = cluster id):

```bash
terraform import yandex_mdb_mysql_cluster.this <cluster_id>
```

Iterate the config until `terraform plan` reports no changes.
