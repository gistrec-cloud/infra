# gcore — geo-routed DNS

The names Cloudflare does not answer for. Russian ISPs throttle foreign origins,
so RF clients must land on an RF address while everyone else stays on the EU one.
Cloudflare geo-steers only on its paid Load Balancing, so such names are
delegated to Gcore one subdomain at a time — the parent zone stays where it is.

Delegated so far: `glucose.gistrec.cloud`.

```
gistrec.cloud (Cloudflare)
  └── glucose.gistrec.cloud  NS → ns1.gcorelabs.net, ns2.gcdn.services
        └── A  94.228.125.88  countries = ["ru"]   → russia-03
            A  62.238.12.36   default              → finland-01
```

Both origins serve the same page — `glucose` on finland-01 renders the snapshot,
`glucose-mirror` on russia-03 pulls it over the wg tunnel every 2 minutes (both
in `ansible/apps.yml`). The TLS wildcard `*.gistrec.cloud` still covers the name
and its DNS-01 still runs in the parent zone, so delegation costs no cert work.

## Filter pipeline

Order matters — filters run as a chain, each narrowing what the next one sees:

1. `geodns` — keep records whose `meta` matches the client (country, here).
2. `default` — if nothing matched, fall back to records marked `default = true`.
   Without this a client outside every rule gets an empty answer.
3. `first_n` (limit 1) — return one record, not the whole survivor set.

## Setup

Token: 1Password item `gcore-token`, exported by `.envrc` as
`TF_VAR_gcore_permanent_api_token`. The DNS **service must be enabled in the
Gcore panel first** — a fresh account reports every service as
`status=new, enabled=False`, and zone creation answers `403 forbidden action`
while listing zones still returns 200.

```bash
terraform -chdir=terraform/gcore plan
```

## Gotchas

- **TTL floor is 120s on the free plan** (`400` below that). That floor is also
  the failover floor: no geo or health change reaches a client faster.
- **`gcore_dns_zone` exposes no nameservers.** They are account-wide and fixed
  (vanity NS are Enterprise-only), so the delegation records in `dns/` are
  written by hand.
- **NS and CNAME cannot coexist on a name**, so delegating meant deleting the old
  `glucose` CNAME in the same apply.
- **No healthchecks yet.** If russia-03 dies, RF clients keep getting its
  address. Adding `filter { type = "is_healthy" }` is the next step — note that
  when *every* healthcheck fails Gcore returns all records anyway, so it filters,
  it does not fail closed.

## Verifying geo rules

Query the Gcore nameservers directly — this works before delegation, so rules can
be checked without any downtime:

```bash
dig +short @ns1.gcorelabs.net glucose.gistrec.cloud A   # from the EU → 62.238.12.36
ssh russia-03 dig +short @ns1.gcorelabs.net glucose.gistrec.cloud A  # from RF → 94.228.125.88
```
