# terraform — DNS as code (Cloudflare)

Manages DNS records for all fleet domains. Domains stay registered at reg.ru /
GoDaddy; their nameservers are delegated to Cloudflare, and records are managed
here. Zones themselves are created in the Cloudflare dashboard — this module
treats them as data (`cloudflare_zone_ids` map) and owns only the records.

## Usage

```bash
cp terraform.tfvars.example terraform.tfvars   # gitignored — put real values here
export TF_VAR_cloudflare_api_token=...          # or set it inside the tfvars file

terraform init
terraform plan
terraform apply
```

## Notes

- `terraform.tfvars`, `*.tfstate` and `.terraform/` are gitignored — no secrets or
  state ever land in the repo.
- Provider pinned to `cloudflare/cloudflare ~> 5.0`, which uses the
  `cloudflare_dns_record` resource and the `content` argument. (Provider v4 used
  `cloudflare_record` + `value`; bump the pin deliberately if you ever change it.)
- Records are driven by the `dns_records` list variable, so adding a record is a
  one-line change in `terraform.tfvars`. Each record names its `zone` (a key of
  `cloudflare_zone_ids`). A `validation` block rejects `proxied = true` on record
  types Cloudflare cannot proxy, and MX records are supported via the optional
  `priority` field.
- Record `name`s are FQDNs exactly as the Cloudflare API returns them — keeps
  imported state and config identical, so plans stay clean.
