resource "authentik_property_mapping_provider_scope" "oidc_profile_names" {
  name       = "OIDC profile: given_name and family_name"
  scope_name = "profile"
  expression = <<EOF
return {
    "given_name": request.user.attributes.get("given_name", ""),
    "family_name": request.user.attributes.get("family_name", ""),
}
EOF
}

locals {
  catalog_custom_group_property_entries = flatten([
    for app_key, config in local.sso_configs : [
      for key, property in config.group_properties : {
        key    = key
        groups = lookup(property, "groups", [])
        name   = lookup(property, "name", null)
        match  = lookup(property, "match", "any")
        scope  = lookup(property, "scope", "profile")
      }
    ]
  ])

  catalog_custom_group_properties = {
    for property in local.catalog_custom_group_property_entries : property.key => {
      groups = property.groups
      name   = property.name
      match  = property.match
      scope  = property.scope
    }
  }

  global_custom_group_properties = {
    for k, v in var.custom_group_properties : k => {
      groups = v.groups
      name   = v.name
      match  = v.match
      scope  = v.scope
    }
  }

  raw_custom_group_properties = merge(
    local.global_custom_group_properties,
    local.catalog_custom_group_properties,
  )

  custom_group_properties = {
    for k, v in local.raw_custom_group_properties : k => merge(v, {
      pretty_name = coalesce(v.name, k)
      joiner      = v.match == "all" ? " and " : " or "
      tests       = [for g in v.groups : "ak_is_group_member(request.user, \"${g}\")"]
    })
  }
}

resource "authentik_property_mapping_provider_scope" "oidc_profile_group_attr" {
  for_each   = local.custom_group_properties
  name       = "OIDC ${each.value.pretty_name} claim"
  scope_name = each.value.scope
  expression = <<EOF
return {
    "${each.key}": ${join(each.value.joiner, each.value.tests)},
}
EOF
}

locals {
  common_oidc_property_mappings = [
    authentik_property_mapping_provider_scope.oidc_profile_names.id,
  ]

  custom_group_property_mapping_ids = {
    for key in keys(authentik_property_mapping_provider_scope.oidc_profile_group_attr) :
    key => authentik_property_mapping_provider_scope.oidc_profile_group_attr[key].id
  }
}
