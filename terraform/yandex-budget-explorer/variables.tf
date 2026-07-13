variable "cloud_id" {
  type = string
}

variable "folder_id" {
  type = string
}

variable "zone" {
  type    = string
  default = "ru-central1-b"
}

variable "functions_source_dir" {
  description = "Local path to the budget-explorer source repo (zip for both functions is built from it)."
  type        = string
  default     = ""
}
