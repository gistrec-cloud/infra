# terraform/yandex-vk-ads-tool — vk-ads-tool folder

Root module for the Yandex Cloud **`vk-ads-tool`** folder (`b1gb7scjmu5adgrjlko7`),
separate from `terraform/yandex` with its own provider `folder_id` and state.

## What it manages (1 resource)

| File         | Resource                | Count | Notes |
|--------------|-------------------------|-------|-------|
| `buckets.tf` | `yandex_storage_bucket` | 1     | `vk-ads-tool-landing` (1 GiB cap) |

The `vk-ads-tool` **compute instance** and its **MySQL database/user** live in the `default`
folder and are managed by `terraform/yandex`, not here.

**Not adopted:** the 2 Cloud Functions `email-sender` and `sentry-to-telegram` — their source
repos aren't on disk, so Terraform can't build a zip to own their deploy. See
[`functions.tf`](functions.tf) for the adoption recipe.

## Usage

```bash
export YC_TOKEN="$(yc config get token)"
cp terraform.tfvars.example terraform.tfvars    # gitignored — fill ids
terraform init && terraform plan                 # expect: No changes
```
