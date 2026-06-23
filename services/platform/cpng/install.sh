#!/bin/bash

helm upgrade --install \
    cnpg \
    --namespace cnpg-system \
    --create-namespace \
    cnpg/cloudnative-pg
