data "authentik_brand" "default" {
  default = true
}

import {
  id = data.authentik_brand.default.id
  to = authentik_brand.default
}

import {
  id = "default-device-code-flow"
  to = authentik_flow.default_device_code
}

data "authentik_provider_oauth2_config" "terraform_cli" {
  name = "Terraform CLI"
}

import {
  id = data.authentik_provider_oauth2_config.terraform_cli.id
  to = authentik_provider_oauth2.terraform_cli
}

import {
  id = "terraform-cli"
  to = authentik_application.terraform_cli
}
