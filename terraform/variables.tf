variable "prefix_slug" {
  description = "The prefix slug for the resources"
  type        = string
}

variable "enable_iam_users" {
  description = "Create bootstrap IAM users and access keys for controllers that later switch to OIDC roles."
  type        = bool
  default     = false
}

variable "enable_oidc_roles" {
  description = "Create the Kubernetes OIDC provider and IAM roles that depend on the published OIDC issuer."
  type        = bool
  default     = true
}
