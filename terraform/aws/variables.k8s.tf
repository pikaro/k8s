variable "external_secrets_ssm_prefix" {
  description = "The prefix for SSM parameters that External Secrets reads from and writes exports beneath."
  type        = string
}
