locals {
  sso_configs_proxy = {
    for k, v in { for a, c in local.sso_configs : a => c if c.protocol == "proxy" } :

    (k) => {
      provider = {
        mode              = lookup(v.protoconf, "mode", "forward_single")
        internal_host     = lookup(v.protoconf, "internal_host", null)
        external_host     = lookup(v.protoconf, "external_host", v.app.url)
        session_hours     = lookup(v.protoconf, "session_hours", 8)
        refresh_hours     = lookup(v.protoconf, "refresh_hours", 0)
        skip_path_regex   = lookup(v.protoconf, "skip_path_regex", null)
        auth_flow         = lookup(v.protoconf, "auth_flow", "implicit")
        invalidation_flow = lookup(v.protoconf, "invalidation_flow", "invalidation")
      }
    }
  }

  valid_proxy_modes = [
    # "proxy",
    "forward_single",
    # "forward_domain",
  ]
}

resource "terraform_data" "validation_appsets_proxy" {
  lifecycle {
    precondition {
      condition     = alltrue([for k, v in local.sso_configs_proxy : contains(local.valid_proxy_modes, v.provider.mode)])
      error_message = "Invalid proxy mode in appset configuration. Valid modes are: ${join(", ", local.valid_proxy_modes)}"
    }

    precondition {
      condition     = alltrue([for k, v in local.sso_configs_proxy : contains(keys(local.auth_flows), v.provider.auth_flow)])
      error_message = "Invalid flow in appset configuration. Valid flows are: ${join(", ", keys(local.auth_flows))}"
    }

    precondition {
      condition     = alltrue([for k, v in local.sso_configs_proxy : contains(keys(local.auth_flows), v.provider.invalidation_flow)])
      error_message = "Invalid invalidation flow in appset configuration. Valid flows are: ${join(", ", keys(local.auth_flows))}"
    }

    precondition {
      condition     = alltrue([for k, v in local.sso_configs_proxy : v.provider.external_host != null])
      error_message = "External host must be defined for each proxy appset configuration."
    }
  }
}

output "sso_configs_proxy" {
  value = local.sso_configs_proxy
}
