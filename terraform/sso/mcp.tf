locals {
  grafana_mcp = {
    client_id   = "grafana-mcp"
    name        = "Grafana MCP"
    slug        = "grafana-mcp"
    namespace   = local.sso_configs["platform/monitoring.yaml"].namespace
    grafana_url = local.sso_configs["platform/monitoring.yaml"].app.url
  }

  grafana_mcp_access_groups = [
    "global-admins",
    "grafana-admins",
  ]
}

resource "authentik_provider_oauth2" "grafana_mcp" {
  name      = local.grafana_mcp.name
  client_id = local.grafana_mcp.client_id

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
  ]
}

resource "authentik_application" "grafana_mcp" {
  name               = local.grafana_mcp.name
  slug               = local.grafana_mcp.slug
  protocol_provider  = authentik_provider_oauth2.grafana_mcp.id
  policy_engine_mode = "any"

  meta_hide = true
}

resource "authentik_policy_binding" "grafana_mcp_groups" {
  for_each = {
    for index, group in local.grafana_mcp_access_groups : group => index
  }

  target = authentik_application.grafana_mcp.uuid
  group  = authentik_group.main[each.key].id
  order  = each.value
}

resource "kubernetes_secret_v1" "grafana_mcp" {
  metadata {
    name      = "grafana-mcp-sso"
    namespace = local.grafana_mcp.namespace

    labels = {
      "app.kubernetes.io/managed-by" = "terraform"
      "app.kubernetes.io/component"  = "sso"
      "app.kubernetes.io/part-of"    = "monitoring"
      "app.kubernetes.io/name"       = "grafana-mcp-sso"
    }

    annotations = {
      "terraform.io/description" = "Grafana MCP temporary-token bootstrap configuration"
    }
  }

  data = {
    authentik_url = local.authentik.url
    grafana_url   = local.grafana_mcp.grafana_url
    client_id     = authentik_provider_oauth2.grafana_mcp.client_id
    device_url    = "${local.authentik.url}/application/o/device/"
    token_url     = "${local.authentik.url}/application/o/token/"
    issuer        = "${local.authentik.url}/application/o/${authentik_application.grafana_mcp.slug}/"
    jwk_set_url   = "${local.authentik.url}/application/o/${authentik_application.grafana_mcp.slug}/jwks/"
    expect_claims = jsonencode({
      iss = "${local.authentik.url}/application/o/${authentik_application.grafana_mcp.slug}/"
    })
  }

  type = "Opaque"
}
