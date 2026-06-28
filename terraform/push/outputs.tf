output "push_url" {
  value = var.public_url
}

output "mobile_user" {
  value = var.mobile_user
}

output "mobile_topics" {
  value = [for severity in local.alert_topic_order : local.alert_topics[severity].topic]
}
