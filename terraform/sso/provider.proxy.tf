resource "authentik_provider_proxy" "main" {
  for_each = local.sso_configs_proxy

  name = local.sso_configs[each.key].app.name

  mode               = each.value.provider.mode
  authorization_flow = local.auth_flows[each.value.provider.auth_flow]
  invalidation_flow  = local.auth_flows[each.value.provider.invalidation_flow]

  access_token_validity  = "hours=${each.value.provider.session_hours}"
  refresh_token_validity = "hours=${each.value.provider.refresh_hours}"

  internal_host = each.value.provider.internal_host
  external_host = each.value.provider.external_host

  skip_path_regex = each.value.provider.skip_path_regex
}

resource "authentik_outpost_provider_attachment" "proxy" {
  for_each = local.sso_configs_proxy

  protocol_provider = authentik_provider_proxy.main[each.key].id
  outpost           = data.authentik_outpost.embedded.id
}
