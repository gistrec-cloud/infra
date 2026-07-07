terraform {
  required_version = ">= 1.7" # for_each in import blocks

  required_providers {
    yandex = {
      source  = "yandex-cloud/yandex"
      version = "~> 0.213"
    }
    archive = {
      source  = "hashicorp/archive"
      version = "~> 2.4"
    }
  }
}
