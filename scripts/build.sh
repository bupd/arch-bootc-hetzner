#!/bin/bash
set -euo pipefail

# Build arch-bootc images and push to a container registry.
#
# Usage:
#   ./scripts/build.sh <registry> <username> <password>
#
# Example:
#   ./scripts/build.sh registry.goharbor.io/bupd/bootc robot_bupd+bootc Harbor12345

REGISTRY="${1:?Usage: $0 <registry> <username> <password>}"
USERNAME="${2:?Usage: $0 <registry> <username> <password>}"
PASSWORD="${3:?Usage: $0 <registry> <username> <password>}"

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_DIR="$(dirname "$SCRIPT_DIR")"
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
    -e "CHUNKAH_CONFIG_STR=${CHUNKAH_CONFIG_STR}" \
    -e "CHUNKAH_ARGS=${CHUNKAH_ARGS}" \
    -e "ARCHIVE_NAME=$(basename "$CHUNKAH_ARCHIVE_PATH")" \
    -v "${SOURCE_MOUNT}:/chunkah:ro" \
    -v "${REPO_DIR}:/out:rw" \
    "$CHUNKAH_IMAGE" \
    sh -ceu 'chunkah build --config-str "$CHUNKAH_CONFIG_STR" ${CHUNKAH_ARGS} > "/out/${ARCHIVE_NAME}"'
IMPORTED_IMAGE="$(sudo podman pull "oci-archive:${CHUNKAH_ARCHIVE_PATH}")"
sudo podman tag "$IMPORTED_IMAGE" "$CHUNKED_IMAGE_TAG"

echo ""
echo "## Pushing to $CHUNKED_IMAGE_TAG"
sudo podman push "$CHUNKED_IMAGE_TAG"

echo ""
echo "## Done. Image pushed to $CHUNKED_IMAGE_TAG"
