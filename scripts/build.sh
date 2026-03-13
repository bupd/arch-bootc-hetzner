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
sudo podman build --network=host \
    --skip-unused-stages=false \
    --build-arg "SOURCE_IMAGE=${FINAL_IMAGE_TAG}" \
    --build-arg "CHUNKAH_IMAGE=${CHUNKAH_IMAGE}" \
    --build-arg "CHUNKAH_CONFIG_STR=${CHUNKAH_CONFIG_STR}" \
    --build-arg "CHUNKAH_ARGS=${CHUNKAH_ARGS}" \
    -f "$REPO_DIR/Containerfile.chunkah" \
    -t "$CHUNKED_IMAGE_TAG" \
    "$REPO_DIR"

echo ""
echo "## Pushing to $CHUNKED_IMAGE_TAG"
sudo podman push "$CHUNKED_IMAGE_TAG"

echo ""
echo "## Done. Image pushed to $CHUNKED_IMAGE_TAG"
