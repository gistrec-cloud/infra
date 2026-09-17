terraform {
  required_version = ">= 1.6"

  required_providers {
    gcore = {
      source  = "G-Core/gcore"
      version = "~> 0.30"
    }
  }
}

# Токен — из окружения (.envrc → 1Password item gcore-token).
provider "gcore" {
  permanent_api_token = var.gcore_permanent_api_token
}
