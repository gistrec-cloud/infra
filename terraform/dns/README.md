# terraform — DNS as code (Cloudflare + Porkbun)

Manages DNS records for all fleet domains. Most domains stay registered at
reg.ru / GoDaddy; their nameservers are delegated to Cloudflare, and records
are managed here. Zones themselves are created in the Cloudflare dashboard —
this module treats them as data (`cloudflare_zone_ids` map) and owns only the
records.

Porkbun-registered zones (dndcrime.com) keep Porkbun nameservers instead —
their records live in `porkbun_records` (see `porkbun.tf`).

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
- A/AAAA/CNAME records are keyed by `zone:type:name`, so a `host`/content flip
  is one atomic in-place update (no destroy+create race, no resolution gap);
  their names must be unique (validated). TXT/MX/NS keep content in the key —
  name duplicates are legal there.
- Record `name`s are FQDNs exactly as the Cloudflare API returns them — keeps
  imported state and config identical, so plans stay clean.

## Porkbun notes

- Provider `cullenmcdermott/porkbun ~> 0.3`, resource `porkbun_dns_record`.
  `name` is the subdomain part only (`""` = apex), `ttl`/`prio` are strings and
  Porkbun's ttl floor is 600. No proxy layer — records are always "grey".
- Keys (`porkbun_api_key` + `porkbun_secret_api_key`) come from the 1P item
  `porkbun-api` via `.envrc`. Each zone must additionally have **API ACCESS
  toggled on** in the Porkbun dashboard (Domain Management → details), or every
  API call fails.
- A fresh Porkbun zone ships parking records (and any hand-made ones) that this
  module knows nothing about — duplicate A records at the apex resolve
  round-robin and break the site. Before the first apply for a zone, list and
  delete the strays:

  ```bash
  curl -sX POST https://api.porkbun.com/api/json/v3/dns/retrieve/<zone> \
    -H 'Content-Type: application/json' \
    -d "{\"apikey\":\"$TF_VAR_porkbun_api_key\",\"secretapikey\":\"$TF_VAR_porkbun_secret_api_key\"}"
  curl -sX POST https://api.porkbun.com/api/json/v3/dns/delete/<zone>/<record-id> \
    -H 'Content-Type: application/json' \
    -d "{\"apikey\":\"$TF_VAR_porkbun_api_key\",\"secretapikey\":\"$TF_VAR_porkbun_secret_api_key\"}"
  ```

  (Or adopt one instead: `terraform import 'porkbun_dns_record.this["<key>"]' <record-id>`.)
