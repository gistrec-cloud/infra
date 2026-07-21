# Environment-level ids. Real values live in the gitignored terraform.tfvars.
# Everything else (the resource inventory) is declared as locals in the per-service
# files, since these modules adopt one concrete Yandex Cloud footprint.

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
