resource "confluent_environment" "gistrec" {
  display_name = "gistrec"
}

# Basic: первый eCKU бесплатный (30 партиций, 20 соединений, 5 МБ/с на запись).
# GCP europe-north1 = Хамина, ближайший регион к finland-01 (Hetzner hel1).
resource "confluent_kafka_cluster" "finland_01" {
  display_name = "finland-01"
  availability = "SINGLE_ZONE"
  cloud        = "GCP"
  region       = "europe-north1"

  # Потолок автоскейла = бесплатный eCKU: выше него compute платный.
  basic {
    max_ecku = 1
  }

  environment {
    id = confluent_environment.gistrec.id
  }

  lifecycle {
    prevent_destroy = true
  }
}
