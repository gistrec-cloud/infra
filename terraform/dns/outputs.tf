output "managed_records" {
  description = "Record names managed by this configuration."
  value       = sort([for r in cloudflare_dns_record.this : r.name])
}
