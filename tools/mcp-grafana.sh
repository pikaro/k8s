#!/bin/bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"

# shellcheck source=tools/lib/mcp-support.sh
source "$SCRIPT_DIR/lib/mcp-support.sh"

require_command curl
require_command jq
require_command yq

TTL_SECONDS="${GRAFANA_MCP_TTL_SECONDS:-28800}"
SERVICE_ACCOUNT_NAME="${GRAFANA_MCP_SERVICE_ACCOUNT_NAME:-codex-mcp-readonly}"
CONFIG_DIR="${XDG_CONFIG_HOME:-$HOME/.config}/grafana-mcp"
TOKEN_FILE="${GRAFANA_MCP_TOKEN_FILE:-$CONFIG_DIR/service-account-token}"
ENV_FILE="${GRAFANA_MCP_ENV_FILE:-$CONFIG_DIR/env}"

catalog_grafana_url="$(yq -r '.authentik.url // ""' "$REPO_ROOT/argocd/catalog/platform/monitoring.yaml")"
authentik_host="$(yq -r '.server.ingress.hosts[0] // ""' "$REPO_ROOT/services/base/authentik/values.yaml")"

GRAFANA_URL="${GRAFANA_URL:-$catalog_grafana_url}"
AUTHENTIK_URL="${AUTHENTIK_URL:-https://$authentik_host}"
CLIENT_ID="${GRAFANA_MCP_CLIENT_ID:-grafana-mcp}"
DEVICE_URL="${GRAFANA_MCP_DEVICE_URL:-${AUTHENTIK_URL%/}/application/o/device/}"
TOKEN_URL="${GRAFANA_MCP_TOKEN_URL:-${AUTHENTIK_URL%/}/application/o/token/}"

[ -n "$GRAFANA_URL" ] && [ "$GRAFANA_URL" != "null" ] \
    || die "could not derive GRAFANA_URL from argocd/catalog/platform/monitoring.yaml"
[ -n "$authentik_host" ] && [ "$authentik_host" != "null" ] \
    || die "could not derive AUTHENTIK_URL from services/base/authentik/values.yaml"

bootstrap_token="$(
    oauth_device_token \
        "$CLIENT_ID" \
        "$DEVICE_URL" \
        "$TOKEN_URL" \
        "openid email profile"
)"

encoded_name="$(url_encode "$SERVICE_ACCOUNT_NAME")"
service_accounts="$(
    grafana_jwt_request \
        GET \
        "${GRAFANA_URL%/}/api/serviceaccounts/search?query=$encoded_name&perpage=100" \
        "$bootstrap_token"
)" || die "Grafana rejected the Authentik bootstrap token. Confirm the monitoring app has restarted after the grafana-mcp-sso Secret was created so [auth.jwt] has a non-empty jwk_set_url."

service_account="$(
    jq -c --arg name "$SERVICE_ACCOUNT_NAME" \
        'first(.serviceAccounts[]? | select(.name == $name)) // empty' \
        <<<"$service_accounts"
)"

if [ -z "$service_account" ]; then
    create_body="$(jq -nc --arg name "$SERVICE_ACCOUNT_NAME" '{name: $name, role: "Viewer", isDisabled: false}')"
    service_account="$(
        grafana_jwt_request \
            POST \
            "${GRAFANA_URL%/}/api/serviceaccounts" \
            "$bootstrap_token" \
            "$create_body"
    )"
fi

service_account_id="$(json_field '.id' <<<"$service_account")"
service_account_role="$(json_field '.role' <<<"$service_account")"
service_account_disabled="$(jq -r '.isDisabled // false' <<<"$service_account")"

[ -n "$service_account_id" ] || die "could not determine Grafana service account id: $service_account"

if [ "$service_account_role" != "Viewer" ] || [ "$service_account_disabled" != "false" ]; then
    echo "refusing to mint MCP token for unexpected Grafana service account state:" >&2
    jq . <<<"$service_account" >&2
    exit 1
fi

token_name="codex-mcp-$(date -u +%Y%m%dT%H%M%SZ)"
token_body="$(jq -nc --arg name "$token_name" --argjson ttl "$TTL_SECONDS" '{name: $name, secondsToLive: $ttl}')"
token_response="$(
    grafana_jwt_request \
        POST \
        "${GRAFANA_URL%/}/api/serviceaccounts/$service_account_id/tokens" \
        "$bootstrap_token" \
        "$token_body"
)"

service_account_token="$(json_field '.key' <<<"$token_response")"
[ -n "$service_account_token" ] || die "Grafana did not return a service account token: $token_response"

mkdir -p "$CONFIG_DIR"
umask 077
printf '%s\n' "$service_account_token" >"$TOKEN_FILE"
chmod 600 "$TOKEN_FILE"

write_shell_env "$ENV_FILE" \
    GRAFANA_URL "$GRAFANA_URL" \
    GRAFANA_SERVICE_ACCOUNT_TOKEN_FILE "$TOKEN_FILE" \
    GRAFANA_MCP_TOKEN_EXPIRES_AT "$(( $(date +%s) + TTL_SECONDS ))"

echo "Wrote Grafana MCP token to $TOKEN_FILE"
echo "Wrote Grafana MCP environment to $ENV_FILE"
