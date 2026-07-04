variable "token" {
  type = string
  # Workaround so Codex doesn't need escalation for `validate`
  default     = "dummy"
  description = "The Authentik API token to use for the provider. This is set automatically by login.sh."
}

variable "branding" {
  type = object({
    title = string
  })

  description = <<EOT
    The branding configuration for the authentik-default brand.

    - title: The title to use for the authentik-default brand.
  EOT
}

variable "certificate" {
  type = object({
    common_name  = string
    organization = string
  })

  description = <<EOT
    The certificate configuration for the authentik-default brand.

    - common_name: The common name to use for the default signing certificate.
    - organization: The organization to use for the default signing certificate.
  EOT
}

variable "users" {
  type = map(object({
    email       = string
    name        = string
    given_name  = optional(string)
    family_name = optional(string)
    path        = optional(string, "")
    groups      = optional(list(string), [])
    active      = optional(bool, true)
    type        = optional(string, "internal")
  }))

  description = <<EOT
    The users to create in authentik.

    - The key of the map is the username of the user.
    - email: The email address of the user.
    - name: The full name of the user.
    - given_name: The given name of the user. Defaults to the first part of the name.
    - family_name: The family name of the user. Defaults to the last part of the name.
    - path: The path of the user. Prefixed with "users/".
    - groups: The groups the user belongs to.
    - active: Whether the user is active.
    - type: The type of the user.
  EOT

  validation {
    condition     = alltrue([for u in values(var.users) : u.email != ""])
    error_message = "All users must have an email address."
  }

  validation {
    condition     = alltrue([for u in values(var.users) : u.name != ""])
    error_message = "All users must have a name."
  }

  validation {
    condition     = alltrue([for u in values(var.users) : strcontains(u.name, " ")])
    error_message = "All users must have a name with at least a first and last name separated by a space."
  }

  validation {
    condition     = alltrue([for u in values(var.users) : contains(["internal", "external", "service_account", "internal_service_account"], u.type)])
    error_message = "Type must be one of: internal, external, service_account, internal_service_account."
  }
}

variable "groups" {
  type = map(object({
    superuser  = optional(bool, false)
    parents    = optional(list(string), [])
    attributes = optional(map(string), {})
  }))

  description = <<EOT
    The groups to create in authentik.

    - superuser: Whether the group is a superuser group.
    - parents: The parent groups of the group.
    - attributes: The attributes of the group.
  EOT
}

resource "terraform_data" "validation_users" {
  lifecycle {
    precondition {
      condition = alltrue([
        for u in values(var.users) :
        alltrue([
          for g in u.groups :
          contains(keys(var.groups), g) || contains(keys(local.directory_groups_flat), g)
        ])
      ])
      error_message = "All groups referenced by users must exist in the groups variable."
    }
  }
}

variable "custom_group_properties" {
  type = map(object({
    groups = list(string)
    name   = optional(string)
    match  = optional(string, "any")
    scope  = optional(string, "profile")
  }))
  default     = {}
  description = <<EOT
    The custom group properties to create in authentik. These define reusable
    OIDC group claims; catalog entries attach them to providers with
    authentik.oidc.groupPropertyMappings.

    - The key of the map is the property.
    - groups: The groups to create the property for.
    - match: Matching mode for the groups: "any" or "all". Defaults to "any".
    - name: The name of the property mapping provider scope. Defaults to the property.
    - scope: The scope of the property mapping provider scope. Defaults to "profile".
  EOT

  validation {
    condition     = alltrue([for p in values(var.custom_group_properties) : length(p.groups) > 0])
    error_message = "All custom group properties must have at least one group."
  }

  validation {
    condition     = alltrue([for p in values(var.custom_group_properties) : contains(["any", "all"], p.match)])
    error_message = "match must be one of: any, all."
  }
}

resource "terraform_data" "validation_custom_group_properties" {
  lifecycle {
    precondition {
      condition     = length(setintersection(toset(keys(local.global_custom_group_properties)), toset(keys(local.catalog_custom_group_properties)))) == 0
      error_message = "Custom group properties must be unique between the Terraform variable and catalog authentik.groupProperties."
    }

    precondition {
      condition = alltrue([
        for p in values(local.raw_custom_group_properties) :
        length(p.groups) > 0
      ])
      error_message = "All custom group properties must have at least one group."
    }

    precondition {
      condition = alltrue([
        for p in values(local.raw_custom_group_properties) :
        contains(["any", "all"], p.match)
      ])
      error_message = "match must be one of: any, all."
    }

    precondition {
      condition = alltrue([
        for p in values(local.raw_custom_group_properties) :
        alltrue([
          for g in p.groups :
          contains(keys(var.groups), g) || contains(keys(local.directory_groups_flat), g)
        ])
      ])
      error_message = "All groups referenced by custom group properties must exist in global groups or catalog directoryGroups."
    }
  }
}
