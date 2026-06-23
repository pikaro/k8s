#!/bin/bash

talosctl patch machineconfig \
    --nodes 95.217.36.114 \
    --patch "@patches/${1}.yaml" \
    --mode=try \
    --timeout=2m
