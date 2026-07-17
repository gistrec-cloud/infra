# Environment-level ids. Real values live in the gitignored terraform.tfvars.
# Everything else (the resource inventory) is declared as locals in the per-service
# files, since these modules adopt one concrete Yandex Cloud footprint.
# Exception: the MySQL database/user inventory is ALSO tfvars-fed — see below.

variable "cloud_id" {
  type = string
}

variable "folder_id" {
  type = string
}

variable "zone" {
  description = "Default zone. Most resources live in ru-central1-b."
  type        = string
  default     = "ru-central1-b"
}

variable "network_id" {
  description = "Existing VPC network id (the auto-created \"default\" network)."
  type        = string
}

variable "subnet_id" {
  description = "Existing subnet id in var.zone (default-ru-central1-b)."
  type        = string
}

variable "monitoring_viewer_user_ids" {
  description = "Personal user-account ids granted folder monitoring.viewer (kept out of git)."
  type        = list(string)
  default     = []
}

variable "realm_status_source_dir" {
  description = "Local path to the realm-status function source repo (zip is built from it). Empty = don't manage the function."
  type        = string
  default     = ""
}

# The MySQL inventory is data, not code: database names double as usernames
# (half of a login pair to a publicly reachable cluster) and enumerate every
# internal project. No defaults on purpose — running without terraform.tfvars
# must fail loud, not quietly plan the destruction of every database.
variable "mysql_databases" {
  description = "Per-app databases on the shared MySQL cluster (gitignored terraform.tfvars)."
  type        = set(string)
}

variable "mysql_users" {
  description = "MySQL users keyed by username (gitignored terraform.tfvars)."
  type = map(object({
    global_permissions = optional(list(string), [])
    permissions = optional(list(object({
      database_name = string
      roles         = list(string)
    })), [])
  }))
}
