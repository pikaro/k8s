#!/bin/bash

{ aws sts get-caller-identity 2>/dev/null | jq; } || aws sso login

REPO_ROOT="$(git rev-parse --show-toplevel)"
ORIG_PWD="$(pwd)"

cd "${REPO_ROOT}" || {
    echo "Failed to change directory to ${REPO_ROOT}"
    exit 1
}

source .venv/bin/activate

eval "$(tools/authentik-cli env)"

cd "${ORIG_PWD}" || {
    echo "Failed to change directory back to ${ORIG_PWD}"
    exit 1
}

export TF_VAR_token="${AUTHENTIK_TOKEN}"
