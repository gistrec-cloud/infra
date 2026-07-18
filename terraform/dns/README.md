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
- Fleet IPs live once, in the `host_ips` map; A records point at a host by name
  (`host = "russia-01"`) instead of a literal `content` IP. Moving an app to
  another VPS is flipping `host` on its records; replacing a VPS behind the same
  name is editing one `host_ips` entry. Off-fleet targets keep literal `content`.
- A/AAAA/CNAME records are keyed by `zone:type:name` (content excluded), so a
  `host`/content flip plans as one in-place update — atomic, no destroy+create
  racing the Cloudflare API and no resolution gap. The trade-off: no two
  pointer records may share a name (a validation enforces it). TXT/MX/NS keep
  content in the key — duplicates of a name are legal there, and replacing
  content should replace the record.
- Record `name`s are FQDNs exactly as the Cloudflare API returns them — keeps
  imported state and config identical, so plans stay clean.
