# Kubernetes MCP Access

Use a dedicated read-only ServiceAccount for local Kubernetes MCP sessions. Do
not point the MCP server at an admin kubeconfig.

The GitOps-managed identity is defined in:

- `argocd/catalog/platform/mcp-access.yaml`
- `services/platform/mcp-access/rbac.yaml`

It grants read access to common operational resources, pod logs, and selected
repo CRDs. It does not grant access to `secrets`, `configmaps`, `pods/exec`, or
any create/update/delete verbs.

## Create a kubeconfig

After ArgoCD syncs `mcp-access`, mint a short-lived token and build a dedicated
kubeconfig:

```sh
TOKEN="$(kubectl -n mcp-access create token codex-mcp-readonly --duration=8h)"
API_SERVER="$(kubectl config view --minify -o jsonpath='{.clusters[0].cluster.server}')"
CA_FILE="$(kubectl config view --minify -o jsonpath='{.clusters[0].cluster.certificate-authority}')"
KUBECONFIG_FILE="$HOME/.kube/codex-mcp-readonly.kubeconfig"

if [ -z "$CA_FILE" ]; then
  CA_FILE="$(mktemp)"
  kubectl config view --minify --raw -o jsonpath='{.clusters[0].cluster.certificate-authority-data}' | base64 -d > "$CA_FILE"
fi

kubectl config --kubeconfig="$KUBECONFIG_FILE" set-cluster thule-mcp \
  --server="$API_SERVER" \
  --certificate-authority="$CA_FILE" \
  --embed-certs=true
kubectl config --kubeconfig="$KUBECONFIG_FILE" set-credentials codex-mcp-readonly \
  --token="$TOKEN"
kubectl config --kubeconfig="$KUBECONFIG_FILE" set-context codex-mcp-readonly \
  --cluster=thule-mcp \
  --user=codex-mcp-readonly \
  --namespace=default
kubectl config --kubeconfig="$KUBECONFIG_FILE" use-context codex-mcp-readonly
chmod 600 "$KUBECONFIG_FILE"
```

If a temporary CA file was created with `mktemp`, remove it after the kubeconfig
has embedded the certificate.

## Run the MCP server

Point the local MCP server at the restricted kubeconfig and keep the server in
read-only, single-cluster mode:

```sh
uvx kubernetes-mcp-server@latest \
  --kubeconfig="$HOME/.kube/codex-mcp-readonly.kubeconfig" \
  --read-only \
  --disable-multi-cluster
```

When configuring the server through an MCP client JSON/TOML file, do not use
`~`. Also avoid `--kubeconfig=~/.kube/...` on the command line: shells expand
`~` at the start of a word, but not inside a long-option assignment. Use
`$HOME`, a separate flag argument, or an absolute path.

Command-line forms that work:

```sh
npx -y kubernetes-mcp-server@latest \
  --kubeconfig "$HOME/.kube/codex-mcp-readonly.kubeconfig" \
  --read-only \
  --disable-multi-cluster

npx -y kubernetes-mcp-server@latest \
  --kubeconfig ~/.kube/codex-mcp-readonly.kubeconfig \
  --read-only \
  --disable-multi-cluster
```

For MCP client JSON/TOML config, use the absolute path:

```json
{
  "args": [
    "--kubeconfig=/Users/david.reis/.kube/codex-mcp-readonly.kubeconfig",
    "--read-only",
    "--disable-multi-cluster"
  ]
}
```

Alternatively set `KUBECONFIG` in the MCP server environment:

```json
{
  "env": {
    "KUBECONFIG": "/Users/david.reis/.kube/codex-mcp-readonly.kubeconfig"
  },
  "args": [
    "--read-only",
    "--disable-multi-cluster"
  ]
}
```

If using a TOML config, also deny sensitive resource kinds at the MCP layer so
the tool surface matches the Kubernetes RBAC boundary:

```toml
read_only = true
cluster_provider_strategy = "disabled"

[[denied_resources]]
group = ""
version = "v1"
kind = "Secret"

[[denied_resources]]
group = ""
version = "v1"
kind = "ConfigMap"
```

## Server-side dry-run

Keep `kubectl apply --dry-run=server` outside this kubeconfig. Kubernetes RBAC
does not provide a dry-run-only permission: a credential that can create/update
for dry-run can usually create/update for real. Use an explicit administrative
approval for those checks instead.
