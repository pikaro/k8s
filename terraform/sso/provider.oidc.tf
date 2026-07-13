resource "random_id" "client_id" {
  for_each = local.sso_configs_oidc

  byte_length = 16
}

resource "authentik_provider_oauth2" "main" {
  for_each = local.sso_configs_oidc

  name = local.sso_configs[each.key].app.name

  client_id               = random_id.client_id[each.key].hex
  client_type             = each.value.provider.client_type
  access_token_validity   = "hours=${each.value.provider.session_hours}"
  refresh_token_threshold = "hours=${each.value.provider.refresh_hours}"

  authorization_flow = local.auth_flows[each.value.provider.auth_flow]
  invalidation_flow  = local.auth_flows[each.value.provider.invalidation_flow]

  signing_key = authentik_certificate_key_pair.main.id

  grant_types = each.value.provider.grant_types

  jwt_federation_providers = each.value.provider.agent_token_auth ? [
    authentik_provider_oauth2.agent.id,
  ] : []

  allowed_redirect_uris = [
    for v in each.value.provider.redirect_uris :
    {
      matching_mode     = "strict"
      redirect_uri_type = "authorization"
      url               = v
    }
  ]

  property_mappings = concat(
    [for v in each.value.provider.oauth_scopes : local.oauth_scopes[v]],
    local.common_oidc_property_mappings,
    [
      for property in each.value.provider.group_property_mappings :
      local.custom_group_property_mapping_ids[property]
    ],
  )
}

resource "kubernetes_secret_v1" "oidc" {
  for_each = local.sso_configs_oidc

  metadata {
    name      = each.value.secret.name
    namespace = local.sso_configs[each.key].namespace

    labels = merge(
      {
        "app.kubernetes.io/managed-by" = "terraform"
        "app.kubernetes.io/component"  = "sso"
      },
      each.value.secret.labels,
    )

    annotations = merge(
      {
        "terraform.io/description" = "${local.sso_configs[each.key].appset_name} OIDC SSO configuration"
      },
      each.value.secret.annotations,
    )
  }

  data = merge(
    {
      issuer          = "${local.authentik.url}/application/o/${authentik_application.main[each.key].slug}/"
      discovery_url   = "${local.authentik.url}/application/o/${authentik_application.main[each.key].slug}/.well-known/openid-configuration/"
      auth_url        = "${local.authentik.url}/application/o/authorize/"
      token_url       = "${local.authentik.url}/application/o/token/"
      api_url         = "${local.authentik.url}/application/o/userinfo/"
      end_session_url = "${local.authentik.url}/application/o/${authentik_application.main[each.key].slug}/end-session/"
      client_id       = authentik_provider_oauth2.main[each.key].client_id
    },
    each.value.provider.client_type == "confidential" ? {
      client_secret = authentik_provider_oauth2.main[each.key].client_secret
    } : {}
  )

  type = "Opaque"
}
