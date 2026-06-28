#!/bin/bash
set -euo pipefail

DEFAULT_NODE="95.217.36.114"
DEFAULT_SCHEMATIC_ID="4dd8e3a8b6203d3c14f049da8db4d3bb0d6d3e70c5e89dfcc1e709e81914f63c"

usage() {
    cat <<'EOF'
Usage: tools/upgrade-to.sh <talos-version|latest> [--force] [--yes]

Upgrades exactly one Talos version hop on the configured node.
Re-run this script for adjacent minor versions, e.g. v1.11.6, then v1.12.9,
then v1.13.5.

Use "latest" to upgrade only to the latest patch of the node's current Talos
minor version. It will not cross minor versions.

Options:
  --force   Skip Talos drain by passing --drain=false to talosctl upgrade.
            This can interrupt workloads, but is useful for a one-node lab.
  --yes     Do not prompt before starting the rebooting upgrade step.
  -h, --help

Environment overrides:
  TALOS_NODE            Node IP to upgrade. Default: 95.217.36.114
  TALOS_ENDPOINT        Talos endpoint. Default: same as TALOS_NODE
  TALOS_SCHEMATIC_ID    Image Factory schematic ID with required extensions.
  TALOS_SNAPSHOT_DIR    Local directory for etcd snapshots. Default: /tmp
  TALOS_UPGRADE_TIMEOUT talosctl upgrade timeout. Default: 30m
  TALOS_HEALTH_TIMEOUT  talosctl health timeout. Default: 20m
  TALOS_DRAIN_TIMEOUT   talosctl drain timeout. Default: 10m
  TALOS_RELEASES_URL    Talos releases API URL.
EOF
}

die() {
    echo "error: $*" >&2
    exit 1
}

run() {
    echo
    printf '==> %s\n' "$*"
    "$@"
}

need_cmd() {
    command -v "$1" >/dev/null 2>&1 || die "missing required command: $1"
}

version_minor() {
    case "$1" in
        v*.*.*)
            printf '%s\n' "$1" | awk -F. '{ print $1 "." $2 }'
            ;;
        *)
            die "invalid Talos version: $1"
            ;;
    esac
}

version_patch() {
    case "$1" in
        v*.*.*)
            printf '%s\n' "$1" | awk -F. '{ print $3 }'
            ;;
        *)
            die "invalid Talos version: $1"
            ;;
    esac
}

current_talos_version() {
    local output

    if ! output="$(talosctl version \
        --nodes "${NODE}" \
        --endpoints "${ENDPOINT}" \
        --short)"; then
        return 1
    fi

    printf '%s\n' "${output}" | awk '
        /^Server:/ {
            server = 1
            next
        }
        server && match($0, /v[0-9]+\.[0-9]+\.[0-9]+/) {
            print substr($0, RSTART, RLENGTH)
            found = 1
            exit
        }
        END {
            if (!found) {
                exit 1
            }
        }
    '
}

latest_patch_for_minor() {
    local minor="$1"

    curl -fsSL "${RELEASES_URL}" |
        sed -n 's/.*"tag_name": "\(v[0-9][0-9]*\.[0-9][0-9]*\.[0-9][0-9]*\)".*/\1/p' |
        awk -F. -v minor="${minor}" '
            ($1 "." $2) == minor && $3 > max_patch {
                max_patch = $3
                latest = $0
            }
            END {
                if (latest == "") {
                    exit 1
                }
                print latest
            }
        '
}

resolve_latest_target() {
    local current_minor
    local current_patch
    local target_minor
    local target_patch

    CURRENT_VERSION="$(current_talos_version)" ||
        die "could not determine current Talos server version"

    current_minor="$(version_minor "${CURRENT_VERSION}")"
    current_patch="$(version_patch "${CURRENT_VERSION}")"

    TARGET_VERSION="$(latest_patch_for_minor "${current_minor}")" ||
        die "could not find latest Talos patch for ${current_minor}"

    target_minor="$(version_minor "${TARGET_VERSION}")"
    target_patch="$(version_patch "${TARGET_VERSION}")"

    if [ "${target_minor}" != "${current_minor}" ]; then
        die "latest resolved to ${TARGET_VERSION}, which would change minor from ${current_minor}"
    fi

    if [ "${target_patch}" -le "${current_patch}" ]; then
        die "node is already at latest ${current_minor} patch (${CURRENT_VERSION})"
    fi

    echo "Resolved latest ${current_minor} patch: ${CURRENT_VERSION} -> ${TARGET_VERSION}"
}

confirm_upgrade() {
    if [ "${ASSUME_YES}" = "true" ]; then
        return
    fi

    if [ ! -t 0 ]; then
        die "refusing to upgrade non-interactively without --yes"
    fi

    echo
    echo "This will reboot Talos node ${NODE} to ${TARGET_VERSION}."
    echo "Snapshot saved at: ${SNAPSHOT_PATH}"
    if [ "${FORCE}" = "true" ]; then
        echo "Force mode is enabled: Talos drain will be skipped."
    fi
    printf 'Type "upgrade %s" to continue: ' "${TARGET_VERSION}"

    if ! read -r answer; then
        die "confirmation was not provided; upgrade cancelled"
    fi
    if [ "${answer}" != "upgrade ${TARGET_VERSION}" ]; then
        die "confirmation did not match; upgrade cancelled"
    fi
}

if [ "$#" -lt 1 ]; then
    usage
    exit 2
fi

case "${1}" in
    -h|--help)
        usage
        exit 0
        ;;
esac

TARGET_ARG="$1"
shift

LATEST_MODE=false

case "${TARGET_ARG}" in
    latest)
        LATEST_MODE=true
        TARGET_VERSION=""
        ;;
    v*)
        TARGET_VERSION="${TARGET_ARG}"
        ;;
    *)
        TARGET_VERSION="v${TARGET_ARG}"
        ;;
esac

FORCE=false
ASSUME_YES=false

while [ "$#" -gt 0 ]; do
    case "$1" in
        --force)
            FORCE=true
            ;;
        --yes|-y)
            ASSUME_YES=true
            ;;
        -h|--help)
            usage
            exit 0
            ;;
        *)
            die "unknown argument: $1"
            ;;
    esac
    shift
done

NODE="${TALOS_NODE:-${NODE:-${DEFAULT_NODE}}}"
ENDPOINT="${TALOS_ENDPOINT:-${ENDPOINT:-${NODE}}}"
SCHEMATIC_ID="${TALOS_SCHEMATIC_ID:-${DEFAULT_SCHEMATIC_ID}}"
SNAPSHOT_DIR="${TALOS_SNAPSHOT_DIR:-/tmp}"
UPGRADE_TIMEOUT="${TALOS_UPGRADE_TIMEOUT:-30m}"
HEALTH_TIMEOUT="${TALOS_HEALTH_TIMEOUT:-20m}"
DRAIN_TIMEOUT="${TALOS_DRAIN_TIMEOUT:-10m}"
RELEASES_URL="${TALOS_RELEASES_URL:-https://api.github.com/repos/siderolabs/talos/releases?per_page=100}"

need_cmd awk
if [ "${LATEST_MODE}" = "true" ]; then
    need_cmd curl
fi
need_cmd date
need_cmd kubectl
need_cmd mkdir
need_cmd sed
need_cmd talosctl
need_cmd tr

if [ "${LATEST_MODE}" = "true" ]; then
    resolve_latest_target
fi

INSTALLER_IMAGE="factory.talos.dev/metal-installer/${SCHEMATIC_ID}:${TARGET_VERSION}"

mkdir -p "${SNAPSHOT_DIR}"

SAFE_NODE="$(printf '%s' "${NODE}" | tr -c 'A-Za-z0-9._-' '_')"
SAFE_VERSION="$(printf '%s' "${TARGET_VERSION}" | tr -c 'A-Za-z0-9._-' '_')"
SNAPSHOT_PATH="${SNAPSHOT_DIR%/}/etcd-${SAFE_NODE}-${SAFE_VERSION}-$(date +%Y%m%d-%H%M%S).snapshot"

echo "Talos upgrade target"
echo "  node:       ${NODE}"
echo "  endpoint:   ${ENDPOINT}"
echo "  version:    ${TARGET_VERSION}"
echo "  image:      ${INSTALLER_IMAGE}"
echo "  snapshot:   ${SNAPSHOT_PATH}"
echo "  drain:      $([ "${FORCE}" = "true" ] && echo "disabled" || echo "enabled")"

run talosctl version --nodes "${NODE}" --endpoints "${ENDPOINT}"
run talosctl get extensions --nodes "${NODE}" --endpoints "${ENDPOINT}"
run kubectl get nodes -o wide
run kubectl get pods -A
run talosctl health \
    --nodes "${NODE}" \
    --endpoints "${ENDPOINT}" \
    --control-plane-nodes "${NODE}" \
    --wait-timeout "${HEALTH_TIMEOUT}"

run talosctl etcd snapshot "${SNAPSHOT_PATH}" \
    --nodes "${NODE}" \
    --endpoints "${ENDPOINT}"

[ -s "${SNAPSHOT_PATH}" ] || die "snapshot was not created or is empty: ${SNAPSHOT_PATH}"

confirm_upgrade

UPGRADE_ARGS=(
    upgrade
    --nodes "${NODE}"
    --endpoints "${ENDPOINT}"
    --image "${INSTALLER_IMAGE}"
    --wait
    --timeout "${UPGRADE_TIMEOUT}"
)

if [ "${FORCE}" = "true" ]; then
    UPGRADE_ARGS+=(--drain=false)
else
    UPGRADE_ARGS+=(--drain-timeout "${DRAIN_TIMEOUT}")
fi

run talosctl "${UPGRADE_ARGS[@]}"

run talosctl version --nodes "${NODE}" --endpoints "${ENDPOINT}"
run talosctl health \
    --nodes "${NODE}" \
    --endpoints "${ENDPOINT}" \
    --control-plane-nodes "${NODE}" \
    --wait-timeout "${HEALTH_TIMEOUT}"
run talosctl get extensions --nodes "${NODE}" --endpoints "${ENDPOINT}"
run kubectl get nodes -o wide
run kubectl get pods -A

if kubectl get namespace openebs >/dev/null 2>&1; then
    run kubectl -n openebs get pods -o wide
fi

echo
echo "Upgrade to ${TARGET_VERSION} completed."
echo "Etcd snapshot: ${SNAPSHOT_PATH}"
