resource "authentik_group" "main" {
  for_each = merge(local.directory_groups_flat, var.groups)
  name     = each.key

  is_superuser = each.value.superuser
  parents      = each.value.parents
  attributes   = jsonencode(each.value.attributes)
}

resource "authentik_user" "main" {
  for_each = var.users

  username = each.key
  name     = each.value.name
  email    = each.value.email
  path     = "users${each.value.path != "" ? "/${each.value.path}" : ""}"

  is_active = each.value.active
  type      = each.value.type

  groups = [
    for v in each.value.groups : authentik_group.main[v].id
  ]
}
