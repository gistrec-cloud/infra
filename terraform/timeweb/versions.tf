terraform {
  required_version = ">= 1.7"

  required_providers {
    twc = {
      source  = "timeweb-cloud/timeweb-cloud"
      version = "~> 1.8"
    }
  }
}
