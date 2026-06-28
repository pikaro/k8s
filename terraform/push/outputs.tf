output "push_url" {
  value = var.public_url
}

output "mobile_user" {
  value = var.mobile_user
}

output "mobile_topics" {
  value = [for severity in local.alert_topic_order : local.alert_topics[severity].topic]
}

output "passwords" {
  value = {
    ntfy_admin        = random_password.ntfy_admin.result
    ntfy_alertmanager = random_password.ntfy_alertmanager.result
    ntfy_mobile       = random_password.ntfy_mobile.result
  }
  sensitive = true
}
