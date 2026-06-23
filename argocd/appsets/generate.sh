#!/bin/bash
SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"

for TYPE in platform base-app app; do
    echo "Generating $TYPE appset"
    export TYPE
    # shellcheck disable=SC2016 # ${TYPE} is shell-format
    envsubst '${TYPE}' <"${SCRIPT_DIR}/template.yaml.tpl" >"${SCRIPT_DIR}/${TYPE}.yaml"
done
