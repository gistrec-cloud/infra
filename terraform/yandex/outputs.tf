output "bucket_names" {
  description = "Adopted Object Storage buckets."
  value       = sort(keys(yandex_storage_bucket.this))
}

output "service_account_ids" {
  description = "Adopted service accounts, name → id."
  value       = { for k, sa in yandex_iam_service_account.this : k => sa.id }
}

output "lockbox_secret_ids" {
  description = "Adopted Lockbox secret containers, name → id."
  value       = { for k, s in yandex_lockbox_secret.this : k => s.id }
}

output "mysql_cluster_id" {
  description = "Managed MySQL cluster id."
  value       = yandex_mdb_mysql_cluster.projects.id
}

output "mysql_databases" {
  description = "Databases in the shared MySQL cluster."
  value       = sort(keys(yandex_mdb_mysql_database.this))
}

output "instance_ids" {
  description = "Adopted Compute instances, name → id."
  value       = { for k, vm in yandex_compute_instance.this : k => vm.id }
}
