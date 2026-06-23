#!/bin/bash

helm upgrade --install \
    cnpg \
    --namespace cnpg-database \
    --create-namespace \
    --values values.yaml \
    cnpg/cluster
