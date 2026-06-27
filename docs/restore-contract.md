# Restore Contract

This is the readiness-scope restore contract. It covers the platform/base stack
needed to converge this repo and recover SSO-protected platform access. It does
not cover post-readiness app data or app-specific secrets such as Vaultwarden,
Vikunja, Odoo, monitoring, or backup-controller credentials.

## Required Inputs

To rebuild the readiness stack from an empty cluster, the inputs are:

- This repository.
- AWS access that can read and update the OpenTofu state bucket.
- OpenTofu state/config for `terraform/aws`.
- OpenTofu state/config for `terraform/sso`, after Authentik is reachable.
- The Kubernetes service-account issuer documents in
  `services/platform/oidc/oidc.json` and `services/platform/oidc/jwks.json`.
- Any SSM parameters referenced by readiness-scope `ExternalSecret` objects.

Current readiness-scope manifests do not reference non-generated SSM-backed
Kubernetes Secrets. The `aws-ssm` `ClusterSecretStore` exists so future
non-generated platform secrets have one owner: SSM Parameter Store, read by
External Secrets.

## Restore Order

1. Bring up the cluster and ArgoCD bootstrap root enough to sync platform
   applications.
2. Apply `terraform/aws` so AWS has the Kubernetes OIDC provider, Route53
   access, external-dns registry, and IAM roles for external-dns, cert-manager,
   and external-secrets.
3. Publish the Kubernetes service-account issuer:
   - Apply the Talos OIDC patch from `bootstrap/talos/patches/oidc.yaml`.
   - Refresh `services/platform/oidc/jwks.json` from the live API server:
     `kubectl get --raw /openid/v1/jwks > services/platform/oidc/jwks.json`.
   - Keep `services/platform/oidc/oidc.json` aligned with
     `https://oidc.k8s.d-reis.com`.
   - Sync the `oidc` platform application.
4. Sync the platform prerequisites needed by the base stack:
   - `openebs`
   - `external-dns`
   - `cert-manager`
   - `traefik`
   - `cnpg-operator`
   - `external-secrets`
5. Sync `cnpg-cluster`.
6. Sync `authentik`.
7. Complete Authentik's first-login bootstrap if this is a new database, create
   or export an admin token, and run `tofu -chdir=terraform/sso apply`.
8. Re-sync SSO consumers that depend on Terraform-written OIDC Secrets, notably
   `argocd`, and verify:
   - ArgoCD login through Authentik.
   - Traefik dashboard forward-auth through Authentik.

If temporary AWS credential Secrets are used before OIDC roles work, they are
bootstrap-only. Remove them after external-dns and cert-manager run through
web-identity roles.

## Secret Ownership

| Secret or credential | Owner | Restore behavior |
| --- | --- | --- |
| external-dns AWS permissions | `terraform/aws` IAM role plus projected service-account token | No Kubernetes Secret in the steady state. |
| cert-manager AWS permissions | `terraform/aws` IAM role plus projected service-account token | No Kubernetes Secret in the steady state. |
| external-secrets AWS permissions | `terraform/aws` IAM role plus projected service-account token | No Kubernetes Secret in the steady state. |
| External Secrets SSM input values | AWS SSM Parameter Store under the configured prefix | Only add readiness-scope non-generated values here; expose them with `ExternalSecret`. |
| `aws-ssm` `ClusterSecretStore` | `services/platform/external-secrets/resources/store.yaml` | Recreated by ArgoCD after the external-secrets CRDs/controller exist. |
| Authentik database password Secret `authentik-db-auth` | ESO `Password` generator in `services/base/authentik/requirements/db-secret.yaml` | Created once in `cnpg-database`; CNPG consumes it for the `authentik` role. |
| Authentik config Secret `authentik-config` | ESO Kubernetes provider plus ESO `Password` generator in `services/base/authentik/requirements/secret-copy.yaml` | Created once in `authentik`; contains generated app secret and copied CNPG credentials. |
| Copied CNPG CA Secret `cnpg-cluster-ca` in `authentik` | ESO Kubernetes provider in `services/base/authentik/requirements/secret-copy.yaml` | Copied from the canonical CNPG CA Secret in `cnpg-database`. |
| ArgoCD OIDC Secret `argocd-sso` | `terraform/sso` `kubernetes_secret_v1.oidc` | Rewritten by OpenTofu from the Authentik provider client data. |
| Authentik users, groups, applications, providers, signing certificate, and proxy outpost attachments | `terraform/sso` | Recreated by running `tofu -chdir=terraform/sso apply` after Authentik is reachable. |
| TLS Secrets for ingress hosts | cert-manager | Recreated from `Certificate` or ingress-shim resources. |
| ACME account private-key Secrets | cert-manager | Recreated by the `ClusterIssuer` flow if absent. |

## Rules

- Do not add a readiness-critical manual `kubectl create secret` step. If the
  secret is non-generated and must survive an empty-cluster rebuild, store it in
  SSM and sync it with External Secrets.
- Do not use Terraform to create app DNS records. `external-dns` and
  cert-manager own DNS records created from Kubernetes resources.
- Keep generated Kubernetes-local credentials generated in Kubernetes unless
  there is a concrete reason they need off-cluster durability.
- Keep post-readiness app secrets out of this contract until those apps become
  readiness gates.
