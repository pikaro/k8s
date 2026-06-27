locals {
  app_providers = merge(
    { for k, v in authentik_provider_oauth2.main : k => v.id },
    { for k, v in authentik_provider_proxy.main : k => v.id }
  )
}

output "app_providers" {
  value = local.app_providers
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
