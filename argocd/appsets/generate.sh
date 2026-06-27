#!/bin/bash
set -euo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
ARGOCD_DIR="$(cd -- "${SCRIPT_DIR}/.." && pwd)"

appset_output_path() {
    case "$1" in
        base)
            printf '%s/base-app.yaml\n' "${SCRIPT_DIR}"
            ;;
        *)
            printf '%s/%s.yaml\n' "${SCRIPT_DIR}" "$1"
            ;;
    esac
}

for TYPE in platform base app; do
    export TYPE

    echo "Generating $TYPE project"
    # shellcheck disable=SC2016 # ${TYPE} is shell-format
    envsubst '${TYPE}' <"${ARGOCD_DIR}/projects/template.yaml.tpl" >"${ARGOCD_DIR}/projects/${TYPE}.yaml"

    echo "Generating $TYPE appset"
    # shellcheck disable=SC2016 # ${TYPE} is shell-format
    envsubst '${TYPE}' <"${SCRIPT_DIR}/template.yaml.tpl" >"$(appset_output_path "${TYPE}")"
done
