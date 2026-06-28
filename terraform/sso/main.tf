terraform {
  required_version = "~> 1.12.0"

  required_providers {
    authentik = {
      source  = "goauthentik/authentik"
      version = "2026.05.0"
    }

    kubernetes = {
      source  = "hashicorp/kubernetes"
      version = "3.2.0"
    }
  }

  backend "s3" {
    bucket       = local.terraform_state_bucket_name
    key          = "sso/terraform.tfstate"
    region       = "eu-central-1"
    use_lockfile = true
  }
}

provider "authentik" {
  url   = local.authentik.url
  token = var.token
}

provider "kubernetes" {
  config_path = "~/.kube/config"
}
