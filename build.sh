#!/bin/bash
. .env

PATCHES=()

if [ "$#" -eq 0 ]; then
    for patch in patches/*; do
        PATCHES+=(--config-patch "@${patch}")
    done
else
    for patch in "$@"; do
        if [ -f "patches/${patch}.yaml" ]; then
            PATCHES+=(--config-patch "patches/${patch}.yaml")
        else
            echo "Patch file patches/${patch}.yaml not found"
            exit 1
        fi
    done
fi

talosctl gen config \
    --force \
    --with-docs=false \
    --with-examples=false \
    --output build/thule.yaml \
    --output-types controlplane \
    "${PATCHES[@]}" \
    --with-secrets build/secrets.yaml \
    --install-image "https://factory.talos.dev/image/${IMAGE_ID}/v${TALOS_VERSION}/metal-amd64.raw.zst" \
    "${CLUSTER_NAME}" \
    "https://${NODE_IP}:6443"
