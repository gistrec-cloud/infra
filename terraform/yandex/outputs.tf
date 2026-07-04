output "bucket_name" {
  value = yandex_storage_bucket.this.bucket
}

output "mysql_cluster_id" {
  value = yandex_mdb_mysql_cluster.this.id
}

output "db_password" {
  description = "Generated MySQL password (also stored in Lockbox)."
  value       = random_password.db.result
  sensitive   = true
}

output "storage_secret_key" {
  description = "Static access secret for the bucket service account."
  value       = yandex_iam_service_account_static_access_key.storage.secret_key
  sensitive   = true
}
