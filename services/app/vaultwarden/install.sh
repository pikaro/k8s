#!/bin/bash

helm -n vaultwarden \
    upgrade --install \
    vaultwarden \
    vaultwarden/vaultwarden \
    -f values.yml \
    "$@"
