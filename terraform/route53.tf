locals {
  root_domain    = "d-reis.com"
  cluster_domain = "k8s.${local.root_domain}"
}

data "aws_route53_zone" "root" {
  name         = "${local.root_domain}."
  private_zone = false
}

data "aws_route53_zone" "k8s" {
  name         = "${local.cluster_domain}."
  private_zone = false
}
