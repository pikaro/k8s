locals {
  authentik_config = yamldecode(file("../../services/base/authentik/values.yaml"))
  authentik_data = {
    hostname = local.authentik_config.server.ingress.hosts[0]
  }
  authentik = merge(
    local.authentik_data,
    {
      url = "https://${local.authentik_data.hostname}"
    }
  )
}
