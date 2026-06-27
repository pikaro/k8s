resource "random_id" "client_id" {
  for_each = { for k, v in local.sso_configs : k => v if v.provider.protocol == "oidc" }

  byte_length = 16
}

resource "authentik_provider_oauth2" "main" {
  for_each = { for k, v in local.sso_configs : k => v if v.provider.protocol == "oidc" }

  name = each.value.provider.name

  client_id               = random_id.client_id[each.key].hex
  client_type             = "confidential"
  access_token_validity   = "hours=${each.value.provider.session_hours}"
  refresh_token_threshold = "hours=${each.value.provider.refresh_hours}"

  authorization_flow = local.auth_flows[each.value.provider.auth_flow]
  invalidation_flow  = local.auth_flows[each.value.provider.invalidation_flow]

  signing_key = authentik_certificate_key_pair.main.id

  property_mappings = [for v in each.value.provider.oauth_scopes : local.oauth_scopes[v]]
}

locals {
  app_providers = merge(
    { for k, v in authentik_provider_oauth2.main : k => v.id },
  )
}

resource "authentik_application" "main" {
  for_each = local.sso_configs

  name              = each.value.app.name
  slug              = each.value.app.slug
  protocol_provider = local.app_providers[each.key]

  meta_hide       = each.value.app.hidden
  group           = each.value.app.group
  meta_icon       = each.value.app.icon
  meta_publisher  = each.value.app.publisher
  meta_launch_url = each.value.app.url
}

resource "kubernetes_secret_v1" "main" {
  for_each = local.sso_configs

  metadata {
    name      = each.value.secret.name
    namespace = each.value.namespace

    labels = merge(
      {
        "app.kubernetes.io/managed-by" = "terraform"
        "app.kubernetes.io/component"  = "sso"
      },
      each.value.secret.labels,
    )

    annotations = merge(
      {
        "terraform.io/description" = "${each.value.app.name} application SSO configuration"
      },
      each.value.secret.annotations,
    )
  }

  data = {
    issuer        = "${local.authentik.url}/application/o/${authentik_application.main[each.key].slug}/"
    client_id     = authentik_provider_oauth2.main[each.key].client_id
    client_secret = authentik_provider_oauth2.main[each.key].client_secret
  }

  type = "Opaque"
}
