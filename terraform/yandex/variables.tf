variable "cloud_id" {
  type = string
}
variable "folder_id" {
  type = string
}
variable "zone" {
  type    = string
  default = "ru-central1-a"
}

variable "network_id" {
  description = "Existing VPC network id (not created here)."
  type        = string
}
variable "subnet_id" {
  description = "Existing subnet id in var.zone (not created here)."
  type        = string
}

# ─── Object Storage ───
variable "bucket_name" {
  description = "Globally-unique Object Storage bucket name."
  type        = string
}

# ─── Managed MySQL ───
variable "mysql_version" {
  type    = string
  default = "8.0"
}
variable "mysql_resource_preset" {
  type    = string
  default = "s2.micro"
}
variable "mysql_disk_size" {
  type    = number
  default = 20
}
variable "mysql_db_name" {
  type    = string
  default = "appdb"
}
variable "mysql_user_name" {
  type    = string
  default = "appuser"
}

# ─── Compute ───
variable "compute_name" {
  type    = string
  default = "app-vm"
}
variable "compute_image_family" {
  type    = string
  default = "ubuntu-2204-lts"
}
variable "compute_cores" {
  type    = number
  default = 2
}
variable "compute_memory" {
  type    = number
  default = 4
}

# ─── Cloud Function ───
variable "function_name" {
  type    = string
  default = "app-fn"
}
variable "function_runtime" {
  type    = string
  default = "python312"
}
variable "function_entrypoint" {
  type    = string
  default = "main.handler"
}
variable "function_zip" {
  description = "Path to the function deployment zip (provided at apply time)."
  type        = string
  default     = "function.zip"
}
