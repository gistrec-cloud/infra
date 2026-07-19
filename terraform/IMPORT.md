# Adopting existing resources (import)

These modules are written **greenfield** (they create resources from scratch). The cloud resources
already exist, so adopt them with `terraform import` instead of letting Terraform recreate them.

## The one rule

> After importing, **never `apply` until `terraform plan` reports `0 to add, 0 to change,
> 0 to destroy`** (beyond the import itself). Any `~` (change) or `-/+` (replace) means your HCL
> diverges from reality — fix the config first, or Terraform will mutate/recreate live resources.

Work **one resource at a time**, safest-first (compute / function / bucket before the database).

## Prerequisites

```bash
brew install terraform            # or opentofu
aws sts get-caller-identity       # confirm AWS auth
yc config list                    # confirm Yandex auth
```

---

## AWS (`terraform/aws`)

### 1. Discover
```bash
aws lambda list-functions --region eu-central-1 --query 'Functions[].FunctionName' --output text
# for each, note its current execution role:
aws lambda get-function-configuration --function-name <name> --region eu-central-1 --query 'Role'
```

### 2. Adjust config for adoption
The module attaches every function to one shared role. Real functions have their own roles, so
`plan` will want to change `role`. Before applying, point each function at its **existing** role
ARN (add a per-function `role` and reference it) — or import those roles too. Do **not** apply a
role change you did not intend.

### 3. Import (id = function name)
```bash
cd terraform/aws
cp terraform.tfvars.example terraform.tfvars   # fill real names/region
terraform init
terraform import 'aws_lambda_function.this["openai-relay"]'      openai-relay
terraform import 'aws_lambda_function_url.this["openai-relay"]'  openai-relay
```

### 4. Verify
```bash
terraform plan     # must show 0 changes before you apply anything
```

---

## Yandex Cloud — three folders, one root module each

The cloud `b1gxxxxxxxxxxxxxxxxx` has **three folders**, each adopted as its own root module
(own provider `folder_id` + own state; ids here are placeholders — the real ones live in each
module's gitignored `terraform.tfvars`):

| Folder | Module | Resources |
|--------|--------|-----------|
| `default` (`b1gyyyyyyyyy-default`) | [`terraform/yandex`](yandex) | 71 |
| `budget-explorer` (`b1gyyyyyyyyyy-budget`) | [`terraform/yandex-budget-explorer`](yandex-budget-explorer) | 10 at adoption (16 now — IAM grants were TF-created later) |
| `vk-ads-tool` (`b1gyyyyyyyyyyy-vkads`) | [`terraform/yandex-vk-ads-tool`](yandex-vk-ads-tool) | 1 |

Apps are split across folders (e.g. `budget-explorer`/`vk-ads-tool` data lives in the shared
MySQL cluster in `default`, their functions/buckets in their own folders). The recipe below
documents the `default` folder; the two sibling modules were adopted the same way.

## `terraform/yandex` (default folder) — DONE ✅

The Yandex footprint has already been adopted: **71 resources** (8 service accounts, 3 Lockbox
secrets, 1 MySQL cluster + 15 databases + 18 users, 5 buckets, 2 compute instances, 18 folder IAM
bindings, 1 Cloud Function) are in state and `terraform plan` reports `No changes`. The module was
rewritten from the greenfield single-app shape into `for_each` maps over a `locals` inventory — see
[`yandex/README.md`](yandex/README.md).

### How it was done (reproducible recipe)

1. **Discover** every object: `yc {compute instance,serverless function,storage bucket} list`,
   `yc managed-mysql {cluster,database,user} list`, `yc iam service-account list`,
   `yc lockbox secret list`.
2. **Harvest ground-truth HCL** instead of hand-writing it — flat `import {}` blocks + generate:
   ```bash
   export YC_TOKEN="$(yc config get token)"
   terraform plan -generate-config-out=generated.tf   # writes exact HCL read from live state
   ```
   (the generator emits a couple of invalid values — `object_size_less_than = 0` on bucket
   lifecycle rules, and `user_hash` for functions — treat `generated.tf` as reference, not final).
3. **Refactor** the harvested resources into `for_each` maps; put real ids in a **gitignored**
   `import.tf` using `for_each` import blocks keyed to match the resources.
4. **Adopt** — never apply until the plan is import-only:
   ```bash
   terraform plan     # must read: "52 to import, 0 to add, 0 to change, 0 to destroy"
   terraform apply    # imports into state; makes NO cloud changes when 0 to change
   terraform plan     # verify: No changes
   ```

### Adoption decisions worth knowing

- **MySQL users** carry `lifecycle { ignore_changes = [password] }` + a placeholder password —
  without it the first `apply` rotates all 18 production passwords.
- **Compute** uses `ignore_changes = [metadata]` (metadata is huge and `private_ui_modified_at`
  changes whenever the VM is opened in the console).
- **Buckets** use `ignore_changes = [lifecycle_rule, logging]` (managed over the S3 API).
- **Folder IAM** uses additive `yandex_resourcemanager_folder_iam_member` (one role↔member each),
  **not** the authoritative `_iam_binding`/`_iam_policy` that would delete any grant not in config.
  Import id format is `folder_id,role,type:subject_id` (comma-separated).
- **Cloud Function `realm-status`** is adopted with Terraform as the deployer: `data.archive_file`
  builds the zip from the source checkout (`realm_status_source_dir`) and `yandex_function`
  publishes a version — a function import is never a 0-change no-op (the deployed `user_hash` isn't
  readable), so the first apply republishes the same code as a fresh version.
- **Not adopted:** `upload-photo-to-recepter-s3` (its source isn't on disk), static access keys
  (secret unrecoverable), Lockbox secret *versions* (payloads), and the auto `default` network /
  subnets / DNS zones.

---

## Alternative: declarative `import {}` blocks (Terraform ≥ 1.5)

Reviewable in a PR, planned before applied. Put real ids in a **gitignored** `import.tf`:

```hcl
import {
  to = aws_lambda_function.this["openai-relay"]
  id = "openai-relay"
}
```
Then `terraform plan -generate-config-out=generated.tf` scaffolds matching config to refine.
Remove the `import {}` blocks once adopted (they are one-shot).

> `import.tf` and `terraform.tfvars` contain real ids — both are already covered by `.gitignore`.
