variable "namespace" {
  description = "Namespace that receives push notification Secrets."
  type        = string
  default     = "observability"
}

variable "public_url" {
  description = "Externally reachable ntfy URL for mobile and browser clients."
  type        = string
  default     = "https://push.d-reis.com"
}

variable "internal_push_host" {
  description = "In-cluster ntfy service host used by Apprise."
  type        = string
  default     = "push.observability.svc.cluster.local"
}

variable "grafana_alerts_url" {
  description = "URL opened from ntfy notifications."
  type        = string
  default     = "https://o11y.d-reis.com/alerting/list"
}

variable "mobile_user" {
  description = "Human ntfy user for mobile alert subscriptions."
  type        = string
  default     = "pikaro"
}
