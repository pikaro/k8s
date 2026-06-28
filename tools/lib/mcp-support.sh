#!/bin/bash

die() {
    echo "$*" >&2
    exit 1
}

require_command() {
    if ! command -v "$1" >/dev/null 2>&1; then
        die "missing required command: $1"
    fi
}

json_field() {
    jq -r "$1 // empty"
}

url_encode() {
    jq -nr --arg v "$1" '$v|@uri'
}

oauth_device_token() {
    local client_id="$1"
    local device_url="$2"
    local token_url="$3"
    local scope="$4"

    local device_response
    device_response="$(
        curl -fsS -X POST "$device_url" \
            -H "Content-Type: application/x-www-form-urlencoded" \
            --data-urlencode "client_id=$client_id" \
            --data-urlencode "scope=$scope"
    )"

    local device_code user_code verification_url expires_in interval
    device_code="$(json_field '.device_code' <<<"$device_response")"
    user_code="$(json_field '.user_code' <<<"$device_response")"
    verification_url="$(json_field '.verification_uri_complete // .verification_uri' <<<"$device_response")"
    expires_in="$(jq -r '.expires_in // 600' <<<"$device_response")"
    interval="$(jq -r '.interval // 5' <<<"$device_response")"

    if [ -z "$device_code" ] || [ -z "$verification_url" ]; then
        echo "invalid device-code response from Authentik:" >&2
        jq . <<<"$device_response" >&2
        return 1
    fi

    echo "Open this URL to authorize Grafana MCP bootstrap:" >&2
    echo "$verification_url" >&2
    echo >&2
    echo "User code: $user_code" >&2

    if [ "${GRAFANA_MCP_OPEN_BROWSER:-1}" != "0" ] && command -v open >/dev/null 2>&1; then
        open "$verification_url" >/dev/null 2>&1 || true
    fi

    local deadline response_file status body error
    deadline=$(($(date +%s) + expires_in))

    while [ "$(date +%s)" -lt "$deadline" ]; do
        response_file="$(mktemp)"
        status="$(
            curl -sS -o "$response_file" -w "%{http_code}" -X POST "$token_url" \
                -H "Content-Type: application/x-www-form-urlencoded" \
                --data-urlencode "grant_type=urn:ietf:params:oauth:grant-type:device_code" \
                --data-urlencode "client_id=$client_id" \
                --data-urlencode "device_code=$device_code" || true
        )"
        body="$(<"$response_file")"
        rm -f "$response_file"

        if [ "$status" = "200" ]; then
            json_field '.access_token' <<<"$body"
            return 0
        fi

        error="$(json_field '.error' <<<"$body" 2>/dev/null || true)"
        case "$error" in
        authorization_pending)
            sleep "$interval"
            ;;
        slow_down)
            interval=$((interval + 5))
            sleep "$interval"
            ;;
        access_denied)
            die "device authorization denied"
            ;;
        expired_token)
            die "device authorization expired"
            ;;
        *)
            echo "unexpected token response from Authentik (HTTP $status):" >&2
            printf '%s\n' "$body" >&2
            return 1
            ;;
        esac
    done

    die "device authorization expired before a token was issued"
}

grafana_jwt_request() {
    local method="$1"
    local url="$2"
    local jwt="$3"
    local data="${4:-}"
    local response_file status

    response_file="$(mktemp)"
    if [ -n "$data" ]; then
        status="$(
            curl -sS -o "$response_file" -w "%{http_code}" -X "$method" "$url" \
                -H "X-JWT-Assertion: $jwt" \
                -H "Content-Type: application/json" \
                -d "$data" || true
        )"
    else
        status="$(
            curl -sS -o "$response_file" -w "%{http_code}" -X "$method" "$url" \
                -H "X-JWT-Assertion: $jwt" || true
        )"
    fi

    if [[ "$status" =~ ^2 ]]; then
        cat "$response_file"
        rm -f "$response_file"
        return 0
    fi

    echo "Grafana API request failed: $method $url returned HTTP $status" >&2
    cat "$response_file" >&2
    echo >&2
    rm -f "$response_file"
    return 1
}

write_shell_env() {
    local path="$1"
    shift

    mkdir -p "$(dirname "$path")"
    umask 077
    : >"$path"

    while [ "$#" -gt 0 ]; do
        printf 'export %s=%q\n' "$1" "$2" >>"$path"
        shift 2
    done

    chmod 600 "$path"
}
