terraform {
  required_version = ">= 1.6"

  required_providers {
    yandex = {
      source  = "yandex-cloud/yandex"
      version = "~> 0.213"
    }
    random = {
      source  = "hashicorp/random"
      version = "~> 3.6"
    }
  }
}
