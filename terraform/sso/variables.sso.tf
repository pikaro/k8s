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
    email  = string
    name   = string
    path   = optional(string, "")
    groups = optional(list(string), [])
    active = optional(bool, true)
    type   = optional(string, "internal")
  }))

  description = <<EOT
    The users to create in authentik.

    - The key of the map is the username of the user.
    - email: The email address of the user.
    - name: The full name of the user.
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
