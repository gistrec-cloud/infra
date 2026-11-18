output "finland_01" {
  description = "Kafka cluster identity and endpoints for clients."
  value = {
    environment_id     = confluent_environment.gistrec.id
    cluster_id         = confluent_kafka_cluster.finland_01.id
    bootstrap_endpoint = confluent_kafka_cluster.finland_01.bootstrap_endpoint
    rest_endpoint      = confluent_kafka_cluster.finland_01.rest_endpoint
  }
}
