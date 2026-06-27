data "authentik_flow" "default_authentication" {
  slug = "default-authentication-flow"
}

data "authentik_flow" "default_invalidation" {
  slug = "default-invalidation-flow"
}

data "authentik_flow" "default_user_settings" {
  slug = "default-user-settings-flow"
}

resource "authentik_brand" "default" {
  domain           = "authentik-default"
  default          = true
  branding_title   = var.branding.title
  branding_favicon = "/static/dist/assets/icons/icon.png"
  branding_logo    = "/static/dist/assets/icons/icon_left_brand.svg"

  flow_authentication = data.authentik_flow.default_authentication.id
  flow_invalidation   = data.authentik_flow.default_invalidation.id
  flow_user_settings  = data.authentik_flow.default_user_settings.id

  flow_device_code = authentik_flow.default_device_code.uuid
}


data "authentik_flow" "default_authorization_implicit_consent" {
  slug = "default-provider-authorization-implicit-consent"
}

data "authentik_flow" "default_authorization_explicit_consent" {
  slug = "default-provider-authorization-explicit-consent"
}

data "authentik_flow" "default_provider_invalidation" {
  slug = "default-provider-invalidation-flow"
}

locals {
  auth_flows = {
    implicit     = data.authentik_flow.default_authorization_implicit_consent.id
    explicit     = data.authentik_flow.default_authorization_explicit_consent.id
    invalidation = data.authentik_flow.default_provider_invalidation.id
  }
}

data "authentik_property_mapping_provider_scope" "profile" {
  managed = "goauthentik.io/providers/oauth2/scope-profile"
}

data "authentik_property_mapping_provider_scope" "email" {
  managed = "goauthentik.io/providers/oauth2/scope-email"
}

data "authentik_property_mapping_provider_scope" "openid" {
  managed = "goauthentik.io/providers/oauth2/scope-openid"
}

data "authentik_property_mapping_provider_scope" "api" {
  managed = "goauthentik.io/providers/oauth2/scope-authentik_api"
}

locals {
  oauth_scopes = {
    profile = data.authentik_property_mapping_provider_scope.profile.id
    email   = data.authentik_property_mapping_provider_scope.email.id
    openid  = data.authentik_property_mapping_provider_scope.openid.id
    api     = data.authentik_property_mapping_provider_scope.api.id
  }
}

data "authentik_user" "akadmin" {
  username = "akadmin"
}

data "authentik_group" "admins" {
  name = "authentik Admins"
}

data "authentik_group" "readonly" {
  name = "authentik Read-only"
}
