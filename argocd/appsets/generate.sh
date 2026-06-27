#!/usr/bin/env bash
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

project_destinations() {
    local type="$1"
    local catalog_dir="${ARGOCD_DIR}/catalog/${type}"
    local file
    local namespace
    local -a namespaces

    mapfile -t namespaces < <(
        for file in "${catalog_dir}"/*.yaml; do
            yq eval -r '.namespace // .name' "${file}"
        done | sort -u
    )

    for namespace in "${namespaces[@]}"; do
        printf '    - server: https://kubernetes.default.svc\n'
        printf '      namespace: %s\n' "${namespace}"
    done
}

for TYPE in platform base app; do
    export TYPE
    PROJECT_DESTINATIONS="$(project_destinations "${TYPE}")"
    export PROJECT_DESTINATIONS

    echo "Generating $TYPE project"
    # shellcheck disable=SC2016 # ${TYPE} and ${PROJECT_DESTINATIONS} are shell-format
    envsubst '${TYPE} ${PROJECT_DESTINATIONS}' <"${ARGOCD_DIR}/projects/template.yaml.tpl" >"${ARGOCD_DIR}/projects/${TYPE}.yaml"

    echo "Generating $TYPE appset"
    # shellcheck disable=SC2016 # ${TYPE} is shell-format
    envsubst '${TYPE}' <"${SCRIPT_DIR}/template.yaml.tpl" >"$(appset_output_path "${TYPE}")"
done
