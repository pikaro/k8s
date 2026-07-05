# Vault

Vault is deployed as a platform service for personal CLI-managed secrets. It
uses integrated Raft storage on a `zfs` PVC and AWS KMS auto-unseal through the
`vault` service account.

The Argo catalog creates the Authentik OIDC client and writes its client
configuration to the `vault-sso` Secret in the `vault` namespace. Vault itself
still needs a one-time post-initialization configuration because auth methods,
policies, audit devices, and secret engines are Vault API state.

## Bootstrap

Apply `terraform/aws` before syncing the ArgoCD Application so the Vault IRSA
role and `alias/vault` KMS alias exist.

After the pod is running for the first time:

```sh
export VAULT_ADDR=https://vault.d-reis.com

vault operator init -recovery-shares=1 -recovery-threshold=1
vault login

vault audit enable file file_path=/vault/audit/audit.log
vault secrets enable -path=kv kv-v2

vault policy write personal-kv - <<'EOF'
path "kv/data/*" {
  capabilities = ["create", "read", "update", "delete", "list"]
}

path "kv/metadata/*" {
  capabilities = ["read", "list", "delete"]
}
EOF
```

Configure OIDC after `terraform/sso apply` has created `vault-sso`:

```sh
OIDC_CLIENT_ID="$(
  kubectl -n vault get secret vault-sso -o jsonpath='{.data.client_id}' | base64 -d
)"
OIDC_CLIENT_SECRET="$(
  kubectl -n vault get secret vault-sso -o jsonpath='{.data.client_secret}' | base64 -d
)"

vault auth enable oidc

vault write auth/oidc/config \
  oidc_discovery_url=https://sso.d-reis.com/application/o/vault/ \
  oidc_client_id="${OIDC_CLIENT_ID}" \
  oidc_client_secret="${OIDC_CLIENT_SECRET}" \
  default_role=personal

vault write auth/oidc/role/personal \
  role_type=oidc \
  user_claim=sub \
  groups_claim=groups \
  oidc_scopes=openid,email,profile \
  allowed_redirect_uris=https://vault.d-reis.com/ui/vault/auth/oidc/oidc/callback,http://localhost:8250/oidc/callback,http://127.0.0.1:8250/oidc/callback \
  token_policies=personal-kv \
  token_ttl=8h
```

CLI login:

```sh
vault login -method=oidc role=personal
vault kv put kv/example value=test
vault kv get kv/example
```
