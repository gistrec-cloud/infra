# Секреты клиентов: `terraform output -json kafka_clients` → 1Password / .env приложений.
output "kafka_clients" {
  description = "Kafka API keys per client service account."
  sensitive   = true
  value = {
    marketdata_collector = {
      key    = confluent_api_key.marketdata_collector.id
      secret = confluent_api_key.marketdata_collector.secret
    }
    clickhouse = {
      key    = confluent_api_key.clickhouse.id
      secret = confluent_api_key.clickhouse.secret
    }
  }
}

output "finland_01" {
  description = "Kafka cluster identity and endpoints for clients."
  value = {
    environment_id     = confluent_environment.gistrec.id
    cluster_id         = confluent_kafka_cluster.finland_01.id
    bootstrap_endpoint = confluent_kafka_cluster.finland_01.bootstrap_endpoint
    rest_endpoint      = confluent_kafka_cluster.finland_01.rest_endpoint
  }
}
