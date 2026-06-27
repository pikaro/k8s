resource "tls_private_key" "main" {
  algorithm   = "ECDSA"
  ecdsa_curve = "P384"
}

resource "tls_self_signed_cert" "main" {
  private_key_pem = tls_private_key.main.private_key_pem

  subject {
    common_name  = var.certificate.common_name
    organization = var.certificate.organization
  }

  validity_period_hours = 87600

  allowed_uses = [
    "key_encipherment",
    "digital_signature",
    "server_auth",
  ]
}

resource "authentik_certificate_key_pair" "main" {
  name             = "main"
  certificate_data = tls_self_signed_cert.main.cert_pem
  key_data         = tls_private_key.main.private_key_pem
}
