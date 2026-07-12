# Vault

Vault is deployed as a platform service for personal CLI-managed secrets and
namespace-isolated Kubernetes workload secrets. It uses integrated Raft
storage on a `zfs` PVC and AWS KMS auto-unseal through the `vault` service
account.

The Argo catalog creates the Authentik OIDC client and writes its client
configuration to the `vault-sso` Secret in the `vault` namespace. Vault API
state is managed by the sibling `~/src/dre/vault` OpenTofu configuration after
the one-time initialization.

## Bootstrap

Apply `terraform/aws` before syncing the ArgoCD Application so the Vault IRSA
role and `alias/vault` KMS alias exist.

After the pod is running for the first time, initialize it and retain the
recovery key securely:

```sh
export VAULT_ADDR=https://vault.d-reis.com

vault operator init -recovery-shares=1 -recovery-threshold=1
vault login
```

Then follow `~/src/dre/vault/README.md` to apply the audit device, KV mounts,
OIDC and Kubernetes auth methods, and policies. Apply `terraform/sso` first so
the `vault-sso` Secret exists.

## Namespace workload access

Participating namespaces use a namespaced External Secrets `SecretStore` and a
`vault-secrets` ServiceAccount. Vault authenticates its projected token and
derives the allowed KV prefix from the service account namespace. A workload
in namespace `example` can therefore use `k8s/example/*` but cannot select a
different namespace through an `ExternalSecret` or `PushSecret`.

The reusable `helm/simple-web-service` chart creates these namespace resources
when machine accounts are present in an application's Authentik catalog entry.

## CLI login

After the sibling Vault OpenTofu configuration has been applied:

```sh
vault login -method=oidc role=personal
vault kv put kv/example value=test
vault kv get kv/example
vault kv get k8s/llama-server/machine-auth/esp32
```
