output "managed_records" {
  description = "Record names managed by this configuration, grouped by zone."
  value = {
    for zone, names in {
      for k, r in cloudflare_dns_record.this : split(":", k)[0] => r.name...
    } : zone => sort(names)
  }
}
