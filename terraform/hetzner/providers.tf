# Authentication comes from HCLOUD_TOKEN. Keep it in 1Password / direnv, never
# in tracked Terraform files or shell history.
provider "hcloud" {}
