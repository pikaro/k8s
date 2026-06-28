resource "random_password" "volsync_restic" {
  length  = 48
  special = false
}

resource "aws_ssm_parameter" "volsync_restic_password" {
  name        = "/${var.external_secrets_ssm_prefix}/volsync/restic-password"
  description = "Shared Restic repository password for VolSync PVC backups."
  type        = "SecureString"
  value       = random_password.volsync_restic.result
}
