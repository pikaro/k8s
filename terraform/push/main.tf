terraform {
  required_version = "~> 1.12.0"

  required_providers {
    kubernetes = {
      source  = "hashicorp/kubernetes"
      version = "3.2.0"
    }

    random = {
      source  = "hashicorp/random"
      version = "3.7.2"
    }
  }

  backend "s3" {
    bucket       = "pikaro-terraform-state"
    key          = "push/terraform.tfstate"
    region       = "eu-central-1"
    use_lockfile = true
  }
}

provider "kubernetes" {
  config_path = "~/.kube/config"
}
