# Adopting existing resources (import)

Most of what these modules manage already existed in the cloud, so the modules are written to
**adopt** it (`terraform import` / `import {}` blocks) rather than create it. The recipes below
record how the AWS and Yandex footprints were adopted, and what to do when a new resource turns up.
`terraform/hetzner` was adopted the same way (see its README); `terraform/dns` started from
imported Cloudflare records but creates new ones outright; `terraform/timeweb` is the full
exception — it created `russia-03` itself.

## The one rule

> After importing, **never `apply` until `terraform plan` reports `0 to add, 0 to change,
> 0 to destroy`** (beyond the import itself). Any `~` (change) or `-/+` (replace) means your HCL
> diverges from reality — fix the config first, or Terraform will mutate/recreate live resources.

Work **one resource at a time**, safest-first (bucket / function before a server or a database).

## Prerequisites

```bash
brew install terraform            # or opentofu
aws sts get-caller-identity       # confirm AWS auth
yc config list                    # confirm Yandex auth
```

---

## AWS (`terraform/aws`)

All three live functions (`openai-relay`, `anthropic-relay`, `yandex-rating-counter`) and their
execution roles are adopted — the recipe below is for the next function that turns up.

### 1. Discover
```bash
aws lambda list-functions --region eu-central-1 --query 'Functions[].FunctionName' --output text
# for each, note its current execution role:
aws lambda get-function-configuration --function-name <name> --region eu-central-1 --query 'Role'
```

### 2. Point the function at its existing role
`main.tf` resolves a function's role itself: explicit `role_arn` > the per-function role from
[`aws/roles.tf`](aws/roles.tf) (matched by function name) > the shared `lambda_exec`, which is
created only when some function has neither. Give a new function one of the first two and import
its role too. Do **not** apply a `role` change you did not intend.

### 3. Import (id = function name)
```bash
cd terraform/aws
cp terraform.tfvars.example terraform.tfvars   # fill real names/region
terraform init
terraform import 'aws_lambda_function.this["<name>"]'      <name>
terraform import 'aws_lambda_function_url.this["<name>"]'  <name>   # only if it has a Function URL
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
| `default` (`b1gyyyyyyyyy-default`) | [`terraform/yandex`](yandex) | 71 at adoption (41 now — MySQL and both VMs destroyed; glucose-bot and the `realm-status` deploy added) |
| `budget-explorer` (`b1gyyyyyyyyyy-budget`) | [`terraform/yandex-budget-explorer`](yandex-budget-explorer) | 10 at adoption (20 now — IAM grants and the Anthropic-relay secrets were TF-created later) |
| `vk-ads-tool` (`b1gyyyyyyyyyyy-vkads`) | [`terraform/yandex-vk-ads-tool`](yandex-vk-ads-tool) | 1 |

Apps are split across folders: `budget-explorer`/`vk-ads-tool` keep their own functions and buckets,
everything else sits in `default`. Relational data is no longer in this cloud at all — the shared
managed MySQL cluster in `default` was destroyed 2026-07-21 once every database had moved to the
self-hosted primary on finland-01 (see the tombstone in [`yandex/mysql.tf`](yandex/mysql.tf)). The
recipe below documents the `default` folder; the two sibling modules were adopted the same way.

## `terraform/yandex` (default folder) — DONE ✅

The Yandex footprint has already been adopted: **41 resources** (11 service accounts, 3 Lockbox
secrets + 3 secret IAM members, 6 buckets + 1 bucket IAM binding, 14 folder IAM grants, 1 Cloud
Function + its trigger and IAM binding) are in state and `terraform plan` reports `No changes`.
Adoption covered **71**: the managed MySQL cluster (1 cluster + 15 databases + 18 users) was
destroyed 2026-07-21, and both compute instances went with russia-02 (2026-07-21) and russia-01
(2026-08-19). The module was rewritten from the greenfield single-app shape into `for_each` maps
over a `locals` inventory — see [`yandex/README.md`](yandex/README.md).

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
   terraform plan     # must read: "<N> to import, 0 to add, 0 to change, 0 to destroy"
   terraform apply    # imports into state; makes NO cloud changes when 0 to change
   terraform plan     # verify: No changes
   ```

### Adoption decisions worth knowing

- **MySQL users** — while the managed cluster existed — carried `lifecycle { ignore_changes =
  [password] }` + a placeholder password; without it the first `apply` would have rotated all 18
  production passwords.
- **Compute** uses `ignore_changes = [metadata]` (metadata is huge and `private_ui_modified_at`
  changes whenever the VM is opened in the console). The `instances` map is empty since russia-01
  was destroyed 2026-08-19; the block stays for the next VM.
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
