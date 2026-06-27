#!/bin/bash

kubectl get -n argocd secret argocd-initial-admin-secret -o json |
    jq .data.password -r |
    base64 -d |
    pbcopy
