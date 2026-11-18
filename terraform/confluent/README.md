# terraform/confluent — Confluent Cloud

Manages the `gistrec` environment and the `finland-01` Kafka cluster (Basic,
GCP `europe-north1` — Hamina, the closest region to the `finland-01` server).
An independent root module with its own state; provider
`confluentinc/confluent ~> 2.0`.

## Cost

Basic bills per eCKU-hour and the first eCKU is free. One eCKU covers 30
partitions, 20 client connections, 5 MBps ingress, 15 MBps egress and
100 requests/s — stay inside that and compute costs nothing. Data in/out and
storage are billed per GB regardless. Managed connectors, Flink and ksqlDB are
paid add-ons and are not used here.

Create topics with 1–3 partitions: the partition and connection limits are the
ones this fleet would hit first.

## Authentication

A Cloud API key (resource management) lives in 1Password; the gitignored root
`.envrc` exports it via direnv:

```bash
export CONFLUENT_CLOUD_API_KEY=$(op read "op://Gistrec Cloud/confluent-cloud-api/api_key")
export CONFLUENT_CLOUD_API_SECRET=$(op read "op://Gistrec Cloud/confluent-cloud-api/secret_api_key")
```

The provider reads both variables directly — the module takes no variables, so
there is no `terraform.tfvars`.

## Notes

- The cluster cannot change cloud or region in place — that is a destroy and
  recreate, hence `prevent_destroy`.
- Kafka API keys for applications (`confluent_api_key`) will put their secrets
  into the state file; keep the state private.
