locals {
  argo_catalog_path  = "${path.module}/../../argocd/catalog"
  argo_catalog_files = fileset(local.argo_catalog_path, "**/*.yaml")

  argo_catalog_configs = {
    for catalog_file in local.argo_catalog_files :
    catalog_file => yamldecode(file("${local.argo_catalog_path}/${catalog_file}"))
  }

  catalog_external_secrets_ssm_parameter_specs = flatten([
    for catalog_file, config in local.argo_catalog_configs : [
      for parameter in try(config.externalSecrets.ssmParameters, []) : {
        catalog_file = catalog_file
        path         = parameter.path
        description  = try(parameter.description, "External Secrets SSM parameter for ${config.name}.")
      }
    ]
  ])

  catalog_external_secrets_ssm_parameter_paths = [
    for parameter in local.catalog_external_secrets_ssm_parameter_specs : parameter.path
  ]

  catalog_external_secrets_ssm_parameters = {
    for parameter in local.catalog_external_secrets_ssm_parameter_specs :
    parameter.path => parameter
  }
}

resource "terraform_data" "catalog_external_secrets_ssm_parameters_validation" {
  lifecycle {
    precondition {
      condition     = length(local.catalog_external_secrets_ssm_parameter_specs) == length(distinct(local.catalog_external_secrets_ssm_parameter_paths))
      error_message = "Duplicate externalSecrets.ssmParameters[].path values are not allowed."
    }

    precondition {
      condition = alltrue([
        for path in local.catalog_external_secrets_ssm_parameter_paths :
        length(path) > 0 && !startswith(path, "/") && !endswith(path, "/")
      ])
      error_message = "externalSecrets.ssmParameters[].path must be a non-empty path relative to var.external_secrets_ssm_prefix."
    }
  }
}

resource "aws_ssm_parameter" "catalog_external_secrets" {
  for_each = local.catalog_external_secrets_ssm_parameters

  name        = "/${var.external_secrets_ssm_prefix}/${each.key}"
  description = each.value.description
  type        = "SecureString"
  value       = "undefined"
  key_id      = local.kms_key_arn

  lifecycle {
    ignore_changes = [value]
  }

  depends_on = [
    terraform_data.catalog_external_secrets_ssm_parameters_validation,
  ]
}
