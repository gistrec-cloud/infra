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
    s3_bucket   = optional(string) # required to CREATE a function; inert for adopted ones (code ships outside TF)
    s3_key      = optional(string)
    memory_size = optional(number, 256)
    timeout     = optional(number, 30)
    env         = optional(map(string), {})
    public_url  = optional(bool)               # true = public URL, false = AWS_IAM URL, omit = no Function URL
    invoke_mode = optional(string, "BUFFERED") # or RESPONSE_STREAM for streaming responses
    role_arn    = optional(string)             # per-function execution role; omit to use the shared one
  }))
  default = {}
}
