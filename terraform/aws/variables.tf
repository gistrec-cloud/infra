variable "aws_region" {
  description = "AWS region for the Lambda functions."
  type        = string
  default     = "eu-central-1"
}

variable "name_prefix" {
  description = "Prefix for IAM resource names."
  type        = string
  default     = "infra"
}

variable "functions" {
  description = <<-EOT
    Lambda functions to manage. Application code ships separately as an S3 artifact, so
    Terraform owns configuration only. Set public_url = true to expose an unauthenticated
    Function URL (authorization_type = NONE).
  EOT
  type = map(object({
    handler     = string
    runtime     = string
    s3_bucket   = string
    s3_key      = string
    memory_size = optional(number, 256)
    timeout     = optional(number, 30)
    env         = optional(map(string), {})
    public_url  = optional(bool, false)
  }))
  default = {}
}
