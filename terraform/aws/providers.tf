# Credentials via env: AWS_ACCESS_KEY_ID / AWS_SECRET_ACCESS_KEY (or a shared profile).
provider "aws" {
  region = var.aws_region
}
