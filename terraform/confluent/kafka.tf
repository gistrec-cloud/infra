# Всё внутри кластера (топики, ACL) провайдер делает Kafka-ключом, а не Cloud-ключом:
# отдельный админ-аккаунт, которым пользуется только Terraform.
resource "confluent_service_account" "tf_admin" {
  display_name = "tf-admin"
  description  = "Terraform: topics and ACLs on finland-01"
}

resource "confluent_role_binding" "tf_admin" {
  principal   = "User:${confluent_service_account.tf_admin.id}"
  role_name   = "CloudClusterAdmin"
  crn_pattern = confluent_kafka_cluster.finland_01.rbac_crn
}

resource "confluent_api_key" "tf_admin" {
  display_name = "tf-admin"
  description  = "Kafka API key of tf-admin (lives in the state only)"

  owner {
    id          = confluent_service_account.tf_admin.id
    api_version = confluent_service_account.tf_admin.api_version
    kind        = confluent_service_account.tf_admin.kind
  }

  managed_resource {
    id          = confluent_kafka_cluster.finland_01.id
    api_version = confluent_kafka_cluster.finland_01.api_version
    kind        = confluent_kafka_cluster.finland_01.kind

    environment {
      id = confluent_environment.gistrec.id
    }
  }

  depends_on = [confluent_role_binding.tf_admin]
}

# ── Market data: сделки с бирж ───────────────────────────────────────────────
# По одной партиции: лимит бесплатного eCKU — 30 партиций на кластер.
# Kafka здесь буфер, архив живёт в ClickHouse — отсюда короткий retention.
locals {
  marketdata_topics = toset([
    "marketdata.binance.trades",
    "marketdata.kraken.trades",
  ])
}

resource "confluent_kafka_topic" "marketdata" {
  for_each = local.marketdata_topics

  topic_name       = each.key
  partitions_count = 1
  rest_endpoint    = confluent_kafka_cluster.finland_01.rest_endpoint

  config = {
    "cleanup.policy" = "delete"
    "retention.ms"   = "259200000" # 3 дня
  }

  kafka_cluster {
    id = confluent_kafka_cluster.finland_01.id
  }

  credentials {
    key    = confluent_api_key.tf_admin.id
    secret = confluent_api_key.tf_admin.secret
  }
}

# Продюсер: коллектор сделок (market-data-collector на finland-01).
resource "confluent_service_account" "marketdata_collector" {
  display_name = "marketdata-collector"
  description  = "Produces exchange trades to marketdata.*"
}

resource "confluent_api_key" "marketdata_collector" {
  display_name = "marketdata-collector"
  description  = "Kafka API key of marketdata-collector"

  owner {
    id          = confluent_service_account.marketdata_collector.id
    api_version = confluent_service_account.marketdata_collector.api_version
    kind        = confluent_service_account.marketdata_collector.kind
  }

  managed_resource {
    id          = confluent_kafka_cluster.finland_01.id
    api_version = confluent_kafka_cluster.finland_01.api_version
    kind        = confluent_kafka_cluster.finland_01.kind

    environment {
      id = confluent_environment.gistrec.id
    }
  }
}

resource "confluent_kafka_acl" "collector_write" {
  resource_type = "TOPIC"
  resource_name = "marketdata."
  pattern_type  = "PREFIXED"
  principal     = "User:${confluent_service_account.marketdata_collector.id}"
  host          = "*"
  operation     = "WRITE"
  permission    = "ALLOW"
  rest_endpoint = confluent_kafka_cluster.finland_01.rest_endpoint

  kafka_cluster {
    id = confluent_kafka_cluster.finland_01.id
  }

  credentials {
    key    = confluent_api_key.tf_admin.id
    secret = confluent_api_key.tf_admin.secret
  }
}

# Консьюмер: ClickHouse на finland-01 (движок Kafka).
resource "confluent_service_account" "clickhouse" {
  display_name = "clickhouse"
  description  = "Consumes marketdata.* into ClickHouse on finland-01"
}

resource "confluent_api_key" "clickhouse" {
  display_name = "clickhouse"
  description  = "Kafka API key of clickhouse"

  owner {
    id          = confluent_service_account.clickhouse.id
    api_version = confluent_service_account.clickhouse.api_version
    kind        = confluent_service_account.clickhouse.kind
  }

  managed_resource {
    id          = confluent_kafka_cluster.finland_01.id
    api_version = confluent_kafka_cluster.finland_01.api_version
    kind        = confluent_kafka_cluster.finland_01.kind

    environment {
      id = confluent_environment.gistrec.id
    }
  }
}

resource "confluent_kafka_acl" "clickhouse_read_topic" {
  resource_type = "TOPIC"
  resource_name = "marketdata."
  pattern_type  = "PREFIXED"
  principal     = "User:${confluent_service_account.clickhouse.id}"
  host          = "*"
  operation     = "READ"
  permission    = "ALLOW"
  rest_endpoint = confluent_kafka_cluster.finland_01.rest_endpoint

  kafka_cluster {
    id = confluent_kafka_cluster.finland_01.id
  }

  credentials {
    key    = confluent_api_key.tf_admin.id
    secret = confluent_api_key.tf_admin.secret
  }
}

resource "confluent_kafka_acl" "clickhouse_read_group" {
  resource_type = "GROUP"
  resource_name = "clickhouse"
  pattern_type  = "PREFIXED"
  principal     = "User:${confluent_service_account.clickhouse.id}"
  host          = "*"
  operation     = "READ"
  permission    = "ALLOW"
  rest_endpoint = confluent_kafka_cluster.finland_01.rest_endpoint

  kafka_cluster {
    id = confluent_kafka_cluster.finland_01.id
  }

  credentials {
    key    = confluent_api_key.tf_admin.id
    secret = confluent_api_key.tf_admin.secret
  }
}
