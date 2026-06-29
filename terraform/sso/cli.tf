resource "authentik_flow" "default_device_code" {
  name               = "Device code flow"
  title              = "Device code flow"
  slug               = "default-device-code-flow"
  designation        = "stage_configuration"
  authentication     = "require_authenticated"
  compatibility_mode = false
}

locals {
  authentik_cli_access_groups = [
    "global-admins",
  ]
}

resource "random_id" "client_id_cli" {
  byte_length = 16
}

resource "authentik_provider_oauth2" "cli" {
  name      = "Authentik CLI"
  client_id = random_id.client_id_cli.hex

  client_type             = "public"
  access_token_validity   = "hours=8"
  refresh_token_threshold = "seconds=0"

  authorization_flow = local.auth_flows.implicit
  invalidation_flow  = local.auth_flows.invalidation

  signing_key = authentik_certificate_key_pair.main.id

  grant_types = ["urn:ietf:params:oauth:grant-type:device_code"]

  property_mappings = [
    local.oauth_scopes.openid,
    local.oauth_scopes.email,
    local.oauth_scopes.profile,
    local.oauth_scopes.api,
  ]
}

resource "authentik_application" "cli" {
  name               = "CLI"
  slug               = "cli"
  protocol_provider  = authentik_provider_oauth2.cli.id
  policy_engine_mode = "any"

  meta_hide = true
}

resource "authentik_policy_binding" "cli_groups" {
  for_each = {
    for index, group in local.authentik_cli_access_groups : group => index
  }

  target = authentik_application.cli.uuid
  group  = authentik_group.main[each.key].id
  order  = each.value
}

output "cli_client_id" {
  value       = authentik_provider_oauth2.cli.client_id
  description = "The client ID for the CLI application."
}
