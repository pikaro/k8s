#!/bin/bash

helm upgrade --install openebs --namespace openebs openebs/openebs --create-namespace --values values.yml
