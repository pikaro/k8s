#!/bin/bash

helm upgrade --install \
    --create-namespace \
    --namespace vikunja \
    vikunja \
    oci://ghcr.io/go-vikunja/helm-chart/vikunja \
    -f values.yml "$@"
