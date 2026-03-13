#!/bin/bash
set -euo pipefail

# Build arch-bootc images and push to a container registry.
#
# Usage:
#   ./scripts/build.sh [registry] [username] [password]
#
# Example:
#   ./scripts/build.sh
#   ./scripts/build.sh registry.goharbor.io/bupd/bootc robot_bupd+bootc Harbor12345

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_DIR="$(dirname "$SCRIPT_DIR")"
ENV_FILE="${REPO_DIR}/.env"

if [ -f "$ENV_FILE" ]; then
    # Load local registry credentials without exporting unrelated shell state.
    set -a
    # shellcheck disable=SC1090
    source "$ENV_FILE"
    set +a
fi

REGISTRY="${1:-${BOOTC_REGISTRY:-}}"
USERNAME="${2:-${BOOTC_USERNAME:-}}"
PASSWORD="${3:-${BOOTC_PASSWORD:-}}"

if [ -z "$REGISTRY" ] || [ -z "$USERNAME" ] || [ -z "$PASSWORD" ]; then
    echo "Usage: $0 [registry] [username] [password]"
    echo "Alternatively set BOOTC_REGISTRY, BOOTC_USERNAME, and BOOTC_PASSWORD in ${ENV_FILE}"
    exit 1
fi

REGISTRY_HOST="$(echo "$REGISTRY" | cut -d/ -f1)"
BASE_IMAGE_TAG="localhost/arch-bootc-base:latest"
FINAL_IMAGE_TAG="localhost/arch-bootc-hetzner:latest"
CHUNKED_IMAGE_TAG="${REGISTRY}:latest"
CHUNKAH_ARCHIVE_PATH="$(mktemp "${REPO_DIR}/chunkah-XXXXXX.ociarchive")"
SOURCE_CID=""

cleanup() {
    if [ -n "$SOURCE_CID" ]; then
        sudo podman unmount "$SOURCE_CID" >/dev/null 2>&1 || true
        sudo podman rm -f "$SOURCE_CID" >/dev/null 2>&1 || true
    fi
    rm -f "$CHUNKAH_ARCHIVE_PATH"
}

trap cleanup EXIT

github_latest_release_tag() {
    local repo="$1"
    curl -fsSL "https://api.github.com/repos/${repo}/releases/latest" | jq -r '.tag_name'
}

BOOTC_VERSION="$(github_latest_release_tag bootc-dev/bootc)"
CHUNKAH_VERSION="$(github_latest_release_tag coreos/chunkah)"

if [ -z "$BOOTC_VERSION" ] || [ "$BOOTC_VERSION" = "null" ]; then
    echo "ERROR: failed to resolve latest bootc release"
    exit 1
fi

if [ -z "$CHUNKAH_VERSION" ] || [ "$CHUNKAH_VERSION" = "null" ]; then
    echo "ERROR: failed to resolve latest chunkah release"
    exit 1
fi

CHUNKAH_IMAGE="quay.io/jlebon/chunkah:${CHUNKAH_VERSION}"
CHUNKAH_ARGS="${CHUNKAH_ARGS:---max-layers 128}"
read -r -a CHUNKAH_ARGS_ARR <<< "$CHUNKAH_ARGS"

echo "## Using bootc ${BOOTC_VERSION}"
echo "## Using chunkah ${CHUNKAH_VERSION}"

echo "## Logging into registry: $REGISTRY_HOST"
sudo podman login "$REGISTRY_HOST" -u "$USERNAME" -p "$PASSWORD"

echo ""
echo "## Building base image (this compiles bootc ${BOOTC_VERSION} from source)"
sudo podman build --pull=always --network=host \
    --build-arg "BOOTC_VERSION=${BOOTC_VERSION}" \
    -f "$REPO_DIR/Containerfile.base" \
    -t "$BASE_IMAGE_TAG" \
    "$REPO_DIR"

echo ""
echo "## Building hetzner image"
sudo podman build --network=host \
    --build-arg "BASE_IMAGE=${BASE_IMAGE_TAG}" \
    -f "$REPO_DIR/Containerfile" \
    -t "$FINAL_IMAGE_TAG" \
    "$REPO_DIR"

echo ""
echo "## Rechunking final image with chunkah"
sudo podman pull "$CHUNKAH_IMAGE"
CHUNKAH_CONFIG_STR="$(sudo podman inspect "$FINAL_IMAGE_TAG" | jq -c '.')"
SOURCE_CID="$(sudo podman create "$FINAL_IMAGE_TAG")"
SOURCE_MOUNT="$(sudo podman mount "$SOURCE_CID")"
sudo podman run --rm \
    -v "${SOURCE_MOUNT}:/chunkah:ro" \
    "$CHUNKAH_IMAGE" \
    build --config-str "$CHUNKAH_CONFIG_STR" "${CHUNKAH_ARGS_ARR[@]}" > "$CHUNKAH_ARCHIVE_PATH"
IMPORTED_IMAGE="$(sudo podman pull "oci-archive:${CHUNKAH_ARCHIVE_PATH}" | tail -n 1)"
sudo podman tag "$IMPORTED_IMAGE" "$CHUNKED_IMAGE_TAG"

echo ""
echo "## Pushing to $CHUNKED_IMAGE_TAG"
sudo podman push "$CHUNKED_IMAGE_TAG"

echo ""
echo "## Done. Image pushed to $CHUNKED_IMAGE_TAG"
