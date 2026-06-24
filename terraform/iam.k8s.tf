resource "aws_iam_openid_connect_provider" "k8s" {
  url = "https://oidc.k8s.d-reis.com"

  client_id_list = ["sts.amazonaws.com"]

  lifecycle {
    enabled = var.enable_oidc_roles
  }
}

locals {
  oidc_sub_claim = "${replace(aws_iam_openid_connect_provider.k8s.url, "https://", "")}:sub"
}
