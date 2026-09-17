# terraform/aws — Lambda functions

Manages the Lambda footprint: three functions (`openai-relay`, `anthropic-relay`,
`yandex-rating-counter`), the two public Function URLs, the per-function IAM roles and customer-managed
policies (`roles.tf`) and the hourly EventBridge Scheduler timer (`schedules.tf`). Configuration only —
application code ships via a separate S3 artifact pipeline, so no `.zip` lives in this repo or in
state. Provider `hashicorp/aws ~> 6.0`.

## Usage

```bash
cp terraform.tfvars.example terraform.tfvars      # gitignored
aws login                                         # session creds; `direnv reload` re-exports them
terraform init && terraform plan
```

## Security note — public Function URLs

`public_url = true` sets `authorization_type = "NONE"`: the URL becomes a **public, unauthenticated
endpoint** — anyone who learns it can invoke the function (and run up your bill). AWS also leaves the
`principal = "*"` invoke permission behind after `destroy`. Use it only for deliberately-open relays,
enforce auth inside the function (or front it with CloudFront/WAF), and never publish the URL — the
`function_urls` output is marked `sensitive`.

## Adoption — done

Everything above was imported, not created: the three functions, their URLs, roles, policies and the
scheduler have been in state since 2026-07-14 (PR #5). One committed change is still unapplied —
`roles.tf` scopes the `lambda-yandex-rating-counter` policy down from `lambda:*` to
`lambda:InvokeFunction` (PR #48, 2026-07-20) — so `terraform plan` shows that one policy update in
place and nothing else.

Import the *next* function that turns up the same way (id = function name) — recipe in
[`../IMPORT.md`](../IMPORT.md); `main.tf` resolves its role itself, so never apply a `role` change you
did not intend.
