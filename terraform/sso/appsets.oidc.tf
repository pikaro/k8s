locals {
  sso_configs_oidc = {
    for k, v in { for a, c in local.sso_configs : a => c if c.protocol == "oidc" } :

    (k) => {
      secret = {
        name        = lookup(v.protoconf, "secret", "${v.appset_name}-sso")
        labels      = lookup(v.protoconf, "secretLabels", {})
        annotations = lookup(v.protoconf, "secretAnnotations", {})
      }

      provider = {
        session_hours     = lookup(v.protoconf, "sessionHours", 8)
        refresh_hours     = lookup(v.protoconf, "refreshHours", 0)
        auth_flow         = lookup(v.protoconf, "authFlow", "implicit")
        invalidation_flow = lookup(v.protoconf, "invalidationFlow", "invalidation")
        oauth_scopes      = lookup(v.protoconf, "oauthScopes", ["openid", "email", "profile"])
        grant_types       = lookup(v.protoconf, "grantTypes", ["authorization_code"])
        redirect_uris = lookup(
          v.protoconf, "redirectUris",
          v.app.url != null ? ["${v.app.url}/auth/callback"] : []
        )
      }
    }
  }

  valid_oidc_grant_types = [
    "authorization_code",
    "implicit",
    "hybrid",
    "refresh_token",
    "client_credentials",
    "password",
    "urn:ietf:params:oauth:grant-type:device_code",
  ]
}

resource "terraform_data" "validation_appsets_oidc" {
  lifecycle {
    precondition {
      condition     = alltrue([for k, v in local.sso_configs_oidc : contains(keys(local.auth_flows), v.provider.auth_flow)])
      error_message = "invalid flow in appset configuration. valid flows are: ${join(", ", keys(local.auth_flows))}"
    }

    precondition {
      condition     = alltrue([for k, v in local.sso_configs_oidc : contains(keys(local.auth_flows), v.provider.invalidation_flow)])
      error_message = "invalid invalidation flow in appset configuration. valid flows are: ${join(", ", keys(local.auth_flows))}"
    }

    precondition {
      condition     = alltrue([for k, v in local.sso_configs_oidc : length(v.provider.oauth_scopes) > 0])
      error_message = "OAuth scopes must be defined for each appset configuration."
    }

    precondition {
      condition     = alltrue([for k, v in local.sso_configs_oidc : alltrue([for scope in v.provider.oauth_scopes : contains(keys(local.oauth_scopes), scope)])])
      error_message = "Invalid OAuth scopes in appset configuration. Valid scopes are: ${join(", ", keys(local.oauth_scopes))}"
    }

    precondition {
      condition     = alltrue([for k, v in local.sso_configs_oidc : length(setsubtract(v.provider.grant_types, local.valid_oidc_grant_types)) == 0])
      error_message = "Invalid grant types in appset configuration. Valid grant types are: ${join(", ", local.valid_oidc_grant_types)}"
    }
  }
}

output "sso_configs_oidc" {
  value = local.sso_configs_oidc
}
