locals {
  argo_catalog = "${path.module}/../../argocd/catalog"
  appsets      = fileset(local.argo_catalog, "**/*.yaml")
  configs = {
    for appset in local.appsets :
    appset => yamldecode(file("${local.argo_catalog}/${appset}"))
  }
  sso_configs = {
    for appset, config in local.configs :

    appset => {
      provider = {
        name              = lookup(config.authentik, "provider", config.name)
        kind              = lookup(config.authentik, "kind", "native")
        protocol          = lookup(config.authentik, "protocol", "oidc")
        session_hours     = lookup(config.authentik, "session_hours", 8)
        refresh_hours     = lookup(config.authentik, "refresh_hours", 0)
        auth_flow         = lookup(config.authentik, "auth_flow", "implicit")
        invalidation_flow = lookup(config.authentik, "invalidation_flow", "invalidation")
        oauth_scopes      = lookup(config.authentik, "oauth_scopes", ["openid", "email", "profile"])
        callback_urls = lookup(
          config.authentik, "callback_urls",
          contains(keys(config.authentik), "url") ? ["${config.authentik.url}/auth/callback"] : null
        )
      }

      app = {
        name      = lookup(config.authentik, "name", title(config.name))
        slug      = lookup(config.authentik, "slug", lower(replace(config.name, "/[^a-zA-Z0-9]+/", "-")))
        group     = lookup(config.authentik, "group", null)
        hidden    = lookup(config.authentik, "hidden", false)
        url       = lookup(config.authentik, "url", null)
        icon      = lookup(config.authentik, "icon", null)
        publisher = lookup(config.authentik, "publisher", null)
      }

      namespace        = lookup(config, "namespace", config.name)
      directory_groups = lookup(config.authentik, "directory_groups", [])
      secret = {
        name        = lookup(config.authentik, "secret", "${config.name}-sso")
        labels      = lookup(config.authentik, "secret_labels", {})
        annotations = lookup(config.authentik, "secret_annotations", {})
      }
    }

    if contains(keys(config), "authentik")
  }

  valid_kinds     = ["native", "proxy"]
  valid_protocols = ["oidc"]
}

resource "terraform_data" "validation_appsets" {
  lifecycle {
    precondition {
      condition     = alltrue([for k, v in local.sso_configs : contains(local.valid_kinds, v.provider.kind)])
      error_message = "Invalid kind in appset configuration. Valid kinds are: ${join(", ", local.valid_kinds)}"
    }

    precondition {
      condition     = alltrue([for k, v in local.sso_configs : contains(local.valid_protocols, v.provider.protocol)])
      error_message = "Invalid protocol in appset configuration. Valid protocols are: ${join(", ", local.valid_protocols)}"
    }

    precondition {
      condition     = alltrue([for k, v in local.sso_configs : contains(keys(local.auth_flows), v.provider.auth_flow)])
      error_message = "Invalid flow in appset configuration. Valid flows are: ${join(", ", keys(local.auth_flows))}"
    }

    precondition {
      condition     = alltrue([for k, v in local.sso_configs : contains(keys(local.auth_flows), v.provider.invalidation_flow)])
      error_message = "Invalid invalidation flow in appset configuration. Valid flows are: ${join(", ", keys(local.auth_flows))}"
    }

    precondition {
      condition     = alltrue([for k, v in local.sso_configs : length(v.provider.oauth_scopes) > 0])
      error_message = "OAuth scopes must be defined for each appset configuration."
    }

    precondition {
      condition     = alltrue([for k, v in local.sso_configs : alltrue([for scope in v.provider.oauth_scopes : contains(keys(local.oauth_scopes), scope)])])
      error_message = "Invalid OAuth scopes in appset configuration. Valid scopes are: ${join(", ", keys(local.oauth_scopes))}"
    }
  }
}

output "sso_configs" {
  value = local.sso_configs
}

locals {
  directory_groups_flat = merge(flatten([
    for k, v in local.sso_configs : [
      for g in v.directory_groups : {
        (g) = {
          superuser  = false
          parents    = []
          attributes = {}
        }
      }
    ]
  ])...)
}
