#!/bin/bash

for TYPE in platform base-app app; do
    echo "Generating $TYPE appset"
    export TYPE
    # shellcheck disable=SC2016 # ${TYPE} is shell-format
    envsubst '${TYPE}' <"template.yaml.tpl" >"${TYPE}.yaml"
done
