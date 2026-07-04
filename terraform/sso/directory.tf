resource "authentik_group" "main" {
  for_each = merge(local.directory_groups_flat, var.groups)
  name     = each.key

  is_superuser = each.value.superuser
  parents      = each.value.parents
  attributes   = jsonencode(each.value.attributes)
}

locals {
  users = {
    for k, v in var.users : k => merge(v, {
      given_name  = coalesce(v.given_name, replace(v.name, "/(.*) .*/", "$1"))
      family_name = coalesce(v.family_name, replace(v.name, "/.* (.*)/", "$1"))
    })
  }
}

resource "authentik_user" "main" {
  for_each = local.users

  username = each.key
  name     = each.value.name
  email    = each.value.email
  path     = "users${each.value.path != "" ? "/${each.value.path}" : ""}"

  is_active = each.value.active
  type      = each.value.type

  attributes = jsonencode({
    given_name  = each.value.given_name
    family_name = each.value.family_name
  })

  groups = [
    for v in each.value.groups : authentik_group.main[v].id
  ]
}
