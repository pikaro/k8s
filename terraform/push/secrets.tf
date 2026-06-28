resource "kubernetes_secret_v1" "ntfy_config" {
  metadata {
    name      = "push-ntfy-config"
    namespace = var.namespace
    labels = {
      "app.kubernetes.io/name"    = "push"
      "app.kubernetes.io/part-of" = "observability"
    }
  }

  data = {
    NTFY_AUTH_USERS  = join(",", local.ntfy_auth_users)
    NTFY_AUTH_ACCESS = join(",", local.ntfy_auth_access)
    NTFY_AUTH_TOKENS = join(",", local.ntfy_auth_tokens)
  }

  type = "Opaque"
}

resource "kubernetes_secret_v1" "apprise_config" {
  metadata {
    name      = "apprise-config"
    namespace = var.namespace
    labels = {
      "app.kubernetes.io/name"    = "apprise"
      "app.kubernetes.io/part-of" = "observability"
    }
  }

  data = {
    "alerts-low.cfg"      = local.apprise_urls.low
    "alerts-medium.cfg"   = local.apprise_urls.medium
    "alerts-high.cfg"     = local.apprise_urls.high
    "alerts-critical.cfg" = local.apprise_urls.critical
  }

  type = "Opaque"
}

resource "kubernetes_secret_v1" "push_mobile" {
  metadata {
    name      = "push-mobile"
    namespace = var.namespace
    labels = {
      "app.kubernetes.io/name"    = "push"
      "app.kubernetes.io/part-of" = "observability"
    }
  }

  data = {
    server_url = var.public_url
    username   = var.mobile_user
    password   = random_password.ntfy_mobile.result
    token      = local.ntfy_mobile_token
    topics     = join(",", [for severity in local.alert_topic_order : local.alert_topics[severity].topic])
  }

  type = "Opaque"
}
