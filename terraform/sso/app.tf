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

  name               = each.value.app.name
  slug               = each.value.app.slug
  protocol_provider  = local.app_providers[each.key]
  policy_engine_mode = length(local.app_access_groups[each.key]) > 0 ? "any" : null

  meta_hide       = each.value.app.hidden
  group           = each.value.app.group
  meta_icon       = each.value.app.icon
  meta_publisher  = each.value.app.publisher
  meta_launch_url = each.value.app.url

  open_in_new_tab = each.value.app.new_tab
}

locals {
  default_app_access_groups = [
    "global-admins",
    "global-users",
  ]

  app_access_groups = {
    for app_key, config in local.sso_configs :
    app_key => distinct(coalesce(config.access_groups, concat(local.default_app_access_groups, config.directory_groups)))
  }

  app_group_bindings = merge({}, [
    for app_key, groups in local.app_access_groups : {
      for index, group in groups :
      "${app_key}:${group}" => {
        app_key = app_key
        group   = group
        order   = index
      }
    }
  ]...)
}

resource "authentik_policy_binding" "app_groups" {
  for_each = local.app_group_bindings

  target = authentik_application.main[each.value.app_key].uuid
  group  = authentik_group.main[each.value.group].id
  order  = each.value.order
}
