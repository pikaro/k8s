# Personal External MCP

Repo-local wrapper for personal, single-principal MCP services backed by
external SaaS credentials.

The chart depends on `javdet/mcp` for the MCP Deployment, Service, Ingress, and
primary ExternalSecret. This wrapper adds the cluster conventions that are not
specific to that generic chart:

- Authentik embedded outpost `IngressRoute`
- ingress-only `NetworkPolicy`
- optional script ConfigMap for gateway stdio commands
- optional extra ExternalSecrets for mounted files
- optional PVCs for service-local mutable state

Each service supplies its backend-specific configuration through the `mcp:`
values block and is expected to use an Authentik catalog entry with
`authentik.accessGroups`.

## Catalog-backed SSM parameters

Services declare required SSM placeholders in their Argo catalog entry under
`externalSecrets.ssmParameters`. `terraform/aws` creates each one at
`/${external_secrets_ssm_prefix}/<path>` as a `SecureString` with the initial
value `undefined` and then ignores future value changes.

The matching Helm values still reference the concrete ExternalSecret
`remoteRef.key` values because ArgoCD and Terraform render independently. The
catalog declaration is authoritative for creating the backing SSM parameter.

Service-specific parameter names and bootstrap steps belong in the owning
`services/app/<name>/README.md` file.

## Service-local state

Use `persistentVolumeClaims` for mutable state that must survive pod restarts
but should not be stored in SSM. Keep bootstrap and cleanup instructions for
that state in the owning service directory.
