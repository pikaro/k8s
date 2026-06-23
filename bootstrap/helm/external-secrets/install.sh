#!/bin/bash

set -eEuo pipefail

helm upgrade --install \
    external-secrets \
    external-secrets/external-secrets \
    -n external-secrets \
    --create-namespace \
    --wait \
    --timeout 5m \
    -f values.yml

kubectl apply -k resources
