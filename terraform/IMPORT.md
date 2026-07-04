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

## Yandex Cloud (`terraform/yandex`)

### 1. Discover
```bash
yc managed-mysql cluster list           # -> cluster id
yc compute instance list                # -> instance id
yc serverless function list             # -> function id
yc storage bucket list                  # -> bucket name
```

### 2. Adjust config for adoption
- **MySQL user password** — add `lifecycle { ignore_changes = [password] }` to
  `yandex_mdb_mysql_user.this`, otherwise `apply` rotates the production DB password to the
  freshly generated one.
- The service account, static access key and Lockbox secret are **new** (created on apply). Keep
  them only if you want them; drop them for a pure adoption.

### 3. Import
```bash
cd terraform/yandex
cp terraform.tfvars.example terraform.tfvars   # fill cloud_id/folder_id/network_id/subnet_id/names
export YC_TOKEN=...                            # (bucket import also needs AWS_ACCESS_KEY_ID/SECRET from a SA static key)
terraform init

terraform import yandex_compute_instance.this       <instance_id>
terraform import yandex_function.this               <function_id>
terraform import yandex_storage_bucket.this         <bucket_name>
terraform import yandex_mdb_mysql_cluster.this       <cluster_id>
terraform import yandex_mdb_mysql_database.this      <cluster_id>:appdb    # verify composite id in provider docs
terraform import yandex_mdb_mysql_user.this          <cluster_id>:appuser  # verify composite id in provider docs
```

### 4. Verify
```bash
terraform plan     # iterate the resource args until this shows 0 changes
```

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
