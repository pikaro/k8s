locals {
  authentik_agent = {
    name      = "authentik-cli"
    slug      = "authentik-cli"
    client_id = "authentik-cli"
  }

  authentik_agent_access_groups = [
    "global-admins",
    "global-users",
  ]
}

resource "authentik_provider_oauth2" "agent" {
  name      = local.authentik_agent.name
  client_id = local.authentik_agent.client_id

  client_type             = "public"
  access_token_validity   = "hours=8"
  refresh_token_validity  = "days=30"
  refresh_token_threshold = "seconds=0"

  authorization_flow = local.auth_flows.implicit
  invalidation_flow  = local.auth_flows.invalidation

  signing_key = authentik_certificate_key_pair.main.id

  grant_types = [
    "urn:ietf:params:oauth:grant-type:device_code",
    "refresh_token",
  ]

  property_mappings = [
    local.oauth_scopes.openid,
    local.oauth_scopes.email,
    local.oauth_scopes.profile,
    local.oauth_scopes.offline_access,
    local.oauth_scopes.api,
  ]
}

resource "authentik_application" "agent" {
  name               = local.authentik_agent.name
  slug               = local.authentik_agent.slug
  protocol_provider  = authentik_provider_oauth2.agent.id
  policy_engine_mode = "any"

  meta_hide = true
}

resource "authentik_policy_binding" "agent_groups" {
  for_each = {
    for index, group in local.authentik_agent_access_groups : group => index
  }

  target = authentik_application.agent.uuid
  group  = authentik_group.main[each.key].id
  order  = each.value
}

resource "authentik_endpoints_connector_agent" "main" {
  name             = "authentik Agent"
  enabled          = true
  refresh_interval = "minutes=30"

  jwt_federation_providers = [
    authentik_provider_oauth2.agent.id,
  ]
}

resource "authentik_endpoints_connector_agent_enrollment_token" "main" {
  connector    = authentik_endpoints_connector_agent.main.id
  name         = "authentik Agent enrollment"
  expiring     = false
  retrieve_key = true
}

output "authentik_agent_enrollment_token" {
  value       = authentik_endpoints_connector_agent_enrollment_token.main.key
  sensitive   = true
  description = "Enrollment token for joining devices to the authentik Agent connector."
}
