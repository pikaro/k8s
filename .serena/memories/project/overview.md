# Project Overview

This repository is the GitOps and OpenTofu source for the Thule Kubernetes
cluster. It manages ArgoCD ApplicationSets, service catalog entries, Helm and
Kustomize service configuration, and OpenTofu modules for AWS, Authentik SSO,
and generated Kubernetes Secrets.

High-level layout:

- `argocd/catalog/{platform,base,app}`: catalog entries consumed by
  ApplicationSet generation and SSO Terraform.
- `argocd/appsets` and `argocd/projects`: generated ApplicationSet and
  AppProject manifests.
- `services/platform`, `services/base`, `services/app`: service-owned Helm
  values, Kustomize resources, and requirements.
- `helm`: repo-local reusable Helm charts.
- `terraform/aws`, `terraform/sso`, `terraform/push`: OpenTofu modules for AWS
  IAM/SSM, Authentik app/secret wiring, and push notification secrets.

`docs/overview.md` is referenced by repo instructions but is not present in
this checkout; `README.md` is the available project overview.
