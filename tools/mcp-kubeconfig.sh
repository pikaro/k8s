#!/bin/bash

TOKEN="$(kubectl -n mcp-access create token codex-mcp-readonly --duration=8h)"
API_SERVER="$(kubectl config view --minify -o jsonpath='{.clusters[0].cluster.server}')"
CA_FILE="$(kubectl config view --minify -o jsonpath='{.clusters[0].cluster.certificate-authority}')"
KUBECONFIG_FILE="$HOME/.kube/codex-mcp-readonly.kubeconfig"

if [ -z "$CA_FILE" ]; then
    CA_FILE="$(mktemp)"
    kubectl config view --minify --raw -o jsonpath='{.clusters[0].cluster.certificate-authority-data}' | base64 -d >"$CA_FILE"
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
