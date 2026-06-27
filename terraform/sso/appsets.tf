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
      appset_name      = config.name
      namespace        = lookup(config, "namespace", config.name)
      protocol         = lookup(config.authentik, "protocol", "oidc")
      name             = lookup(config.authentik, "name", config.name)
      directory_groups = lookup(config.authentik, "directory_groups", [])

      app = {
        name      = lookup(config.authentik, "name", title(config.name))
        slug      = lookup(config.authentik, "slug", lower(replace(config.name, "/[^a-zA-Z0-9]+/", "-")))
        group     = lookup(config.authentik, "group", null)
        hidden    = lookup(config.authentik, "hidden", false)
        url       = lookup(config.authentik, "url", null)
        icon      = lookup(config.authentik, "icon", null)
        publisher = lookup(config.authentik, "publisher", null)
      }

      protoconf = lookup(config.authentik, lookup(config.authentik, "protocol", "oidc"), {})
    }

    if contains(keys(config), "authentik")
  }

  valid_protocols = [
    "oidc",
    "proxy",
  ]
}

resource "terraform_data" "validation_appsets" {
  lifecycle {
    precondition {
      condition     = alltrue([for k, v in local.sso_configs : contains(local.valid_protocols, v.protocol)])
      error_message = "Invalid protocol in appset configuration. Valid protocols are: ${join(", ", local.valid_protocols)}"
    }

    precondition {
      condition     = alltrue([for k, v in local.sso_configs : contains(keys(v), "name")])
      error_message = "Missing 'name' in appset configuration."
    }
  }
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

output "sso_configs" {
  value = local.sso_configs
}
