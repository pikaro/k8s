resource "random_password" "ntfy_admin" {
  length  = 32
  special = false
}

resource "random_password" "ntfy_alertmanager" {
  length  = 32
  special = false
}

resource "random_password" "ntfy_mobile" {
  length  = 32
  special = false
}

resource "random_password" "alertmanager_token_body" {
  length  = 29
  upper   = false
  special = false
}

resource "random_password" "mobile_token_body" {
  length  = 29
  upper   = false
  special = false
}

locals {
  alert_topic_order = ["low", "medium", "high", "critical"]

  alert_topics = {
    low = {
      topic = "alerts-low"
    }
    medium = {
      topic = "alerts-medium"
    }
    high = {
      topic = "alerts-high"
    }
    critical = {
      topic = "alerts-critical"
    }
  }

  ntfy_alertmanager_token = "tk_${random_password.alertmanager_token_body.result}"
  ntfy_mobile_token       = "tk_${random_password.mobile_token_body.result}"

  ntfy_auth_users = [
    "admin:${random_password.ntfy_admin.bcrypt_hash}:admin",
    "alertmanager:${random_password.ntfy_alertmanager.bcrypt_hash}:user",
    "${var.mobile_user}:${random_password.ntfy_mobile.bcrypt_hash}:user",
  ]

  ntfy_auth_access = [
    "alertmanager:alerts-*:write-only",
    "${var.mobile_user}:alerts-*:read-only",
  ]

  ntfy_auth_tokens = [
    "alertmanager:${local.ntfy_alertmanager_token}:Alertmanager",
    "${var.mobile_user}:${local.ntfy_mobile_token}:Mobile alerts",
  ]

  # Alertmanager publishes mobile push directly to ntfy. Keep Apprise empty
  # until non-ntfy fanout destinations, such as email, are configured.
  apprise_urls = {
    for severity in local.alert_topic_order :
    severity => ""
  }
}
