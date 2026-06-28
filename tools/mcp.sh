#!/bin/bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

"$SCRIPT_DIR/mcp-kubeconfig.sh"
"$SCRIPT_DIR/mcp-grafana.sh"

cat <<'EOF'

MCP credentials refreshed.

Kubernetes MCP:
  uvx kubernetes-mcp-server@latest --kubeconfig="$HOME/.kube/codex-mcp-readonly.kubeconfig" --read-only --disable-multi-cluster

Grafana MCP:
  source "$HOME/.config/grafana-mcp/env"
  uvx mcp-grafana

MCP client wrapper form for Grafana:
  bash -lc 'source "$HOME/.config/grafana-mcp/env"; exec uvx mcp-grafana'
EOF
