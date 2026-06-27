resource "authentik_flow" "default_device_code" {
  name               = "Device code flow"
  title              = "Device code flow"
  slug               = "default-device-code-flow"
  designation        = "stage_configuration"
  authentication     = "require_authenticated"
  compatibility_mode = false
}

resource "authentik_provider_oauth2" "terraform_cli" {
  name      = "Terraform CLI"
  client_id = "undefined"

  client_type             = "public"
  access_token_validity   = "hours=8"
  refresh_token_threshold = "seconds=0"

  authorization_flow = local.auth_flows.implicit
  invalidation_flow  = local.auth_flows.invalidation

  signing_key = authentik_certificate_key_pair.main.id

  property_mappings = [
    local.oauth_scopes.openid,
    local.oauth_scopes.email,
    local.oauth_scopes.profile,
    local.oauth_scopes.api,
  ]

  lifecycle {
    # Not available through the API
    ignore_changes = [client_id]
  }
}

resource "authentik_application" "terraform_cli" {
  name              = "Terraform CLI"
  slug              = "terraform-cli"
  protocol_provider = authentik_provider_oauth2.terraform_cli.id

  meta_hide = true
}
