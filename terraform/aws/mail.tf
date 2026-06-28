resource "random_password" "mail_relay_sender" {
  length  = 48
  special = false
}

resource "aws_ssm_parameter" "mail_relay_sender_password" {
  name        = "/${var.external_secrets_ssm_prefix}/mail-relay/sender-password"
  description = "Shared SMTP password for app-to-relay submission."
  type        = "SecureString"
  value       = random_password.mail_relay_sender.result
}

resource "aws_ssm_parameter" "mail_relay_sender_password_hash" {
  name        = "/${var.external_secrets_ssm_prefix}/mail-relay/sender-password-hash"
  description = "Bcrypt hash of the shared SMTP relay submission password for Maddy."
  type        = "SecureString"
  value       = random_password.mail_relay_sender.bcrypt_hash
}
