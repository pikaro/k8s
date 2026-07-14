locals {
  app_service_accounts = merge({}, [
    for app_key, config in local.sso_configs : {
      for account_key, account in config.service_accounts :
      "${app_key}:${account_key}" => {
        app_key       = app_key
        account_key   = account_key
        username      = lookup(account, "username", "${config.app.slug}-${account_key}")
        name          = lookup(account, "name", "${config.app.name} ${account_key}")
        secret_name   = lookup(account, "secretName", "${config.appset_name}-${account_key}-auth")
        namespace     = config.namespace
        token_id      = "${config.app.slug}-${account_key}"
        binding_order = length(local.app_access_groups[app_key]) + index(sort(keys(config.service_accounts)), account_key)
      }
    }
  ]...)
}

resource "authentik_user" "app_service_account" {
  for_each = local.app_service_accounts

  username = each.value.username
  name     = each.value.name
  path     = "services/${local.sso_configs[each.value.app_key].app.slug}"
  type     = "service_account"
}

resource "authentik_token" "app_service_account" {
  for_each = local.app_service_accounts

  identifier   = each.value.token_id
  user         = authentik_user.app_service_account[each.key].id
  description  = "Static machine credential for ${local.sso_configs[each.value.app_key].app.name}."
  intent       = "app_password"
  expiring     = false
  retrieve_key = true
}

resource "authentik_policy_binding" "app_service_account" {
  for_each = local.app_service_accounts

  target = authentik_application.main[each.value.app_key].uuid
  user   = authentik_user.app_service_account[each.key].id
  order  = each.value.binding_order
}

resource "kubernetes_secret_v1" "app_service_account" {
  for_each = local.app_service_accounts

  metadata {
    name      = each.value.secret_name
    namespace = each.value.namespace

    labels = {
      "app.kubernetes.io/managed-by" = "terraform"
      "app.kubernetes.io/component"  = "machine-auth"
      "d-reis.com/authentik-app"     = local.sso_configs[each.value.app_key].app.slug
      "d-reis.com/machine-account"   = each.value.account_key
    }

    annotations = {
      "terraform.io/description" = "${local.sso_configs[each.value.app_key].appset_name} machine authentication credential"
    }
  }

  data = {
    username           = authentik_user.app_service_account[each.key].username
    password           = authentik_token.app_service_account[each.key].key
    authorization      = "Basic ${base64encode("${authentik_user.app_service_account[each.key].username}:${authentik_token.app_service_account[each.key].key}")}"
    authentik_username = authentik_user.app_service_account[each.key].username
  }

  type = "Opaque"
}

output "app_service_accounts" {
  value = {
    for key, account in local.app_service_accounts : key => {
      username    = account.username
      secret_name = account.secret_name
      namespace   = account.namespace
    }
  }
}
