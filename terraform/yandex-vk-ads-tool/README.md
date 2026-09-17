# terraform/yandex-vk-ads-tool — vk-ads-tool folder

Root module for the Yandex Cloud **`vk-ads-tool`** folder (`b1gyyyyyyyyyyy-vkads` — real id
in the gitignored `terraform.tfvars`), separate from `terraform/yandex` with its own provider
`folder_id` and state.

## What it manages (1 resource)

| File         | Resource                | Count | Notes |
|--------------|-------------------------|-------|-------|
| `buckets.tf` | `yandex_storage_bucket` | 1     | `vk-ads-tool-landing` (1 GiB cap) |

The `vk-ads-tool` **compute instance** (`russia-02`) and the shared managed MySQL cluster that
held its database/user were both destroyed 2026-07-21; with `russia-01` gone too (2026-08-19),
`terraform/yandex` manages no compute instances any more. The app now runs on `russia-03`; its
`vk-ads-tool` / `vk-ads-tool-test` databases live on the self-hosted MySQL primary `finland-01`,
registered in `ansible/group_vars/db.yml` (gitignored; `db.yml.example` is in git), not Terraform.

**Not adopted:** the 2 Cloud Functions `email-sender` and `sentry-to-telegram` — their source
repos aren't on disk, so Terraform can't build a zip to own their deploy. See
[`functions.tf`](functions.tf) for the adoption recipe.

## Usage

```bash
export YC_TOKEN="$(yc config get token)"
cp terraform.tfvars.example terraform.tfvars    # gitignored — fill ids
terraform init && terraform plan                 # expect: No changes
```
