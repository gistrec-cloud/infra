# terraform/aws — Lambda functions

Manages AWS Lambda functions (configuration only — application code ships via a separate S3 artifact
pipeline, so no `.zip` lives in this repo or in state). Provider `hashicorp/aws ~> 6.0`.

## Usage

```bash
cp terraform.tfvars.example terraform.tfvars      # gitignored
export AWS_ACCESS_KEY_ID=... AWS_SECRET_ACCESS_KEY=...
terraform init && terraform plan
```

## Security note — public Function URLs

`public_url = true` sets `authorization_type = "NONE"`: the URL becomes a **public, unauthenticated
endpoint** — anyone who learns it can invoke the function (and run up your bill). AWS also leaves the
`principal = "*"` invoke permission behind after `destroy`. Use it only for deliberately-open relays,
enforce auth inside the function (or front it with CloudFront/WAF), and never publish the URL — the
`function_urls` output is marked `sensitive`.

## Adopting the existing functions

The relays already exist — import instead of recreating (import id = function name):

```bash
terraform import 'aws_lambda_function.this["openai-relay"]' openai-relay
```

Iterate the config until `terraform plan` shows no changes, then Terraform owns them as code.
