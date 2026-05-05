#!/bin/bash
set -euo pipefail

# Build arch-bootc images and push to one or more container registries.
#
# Usage:
#   ./scripts/build.sh [image-ref] [username] [password]
#
# Example:
#   ./scripts/build.sh
#   ./scripts/build.sh ghcr.io/bupd/bootc your-github-username your-ghcr-token
#   BOOTC_IMAGE_REFS="ghcr.io/bupd/bootc docker.io/bupd/bootc" ./scripts/build.sh

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_DIR="$(dirname "$SCRIPT_DIR")"
ENV_FILE="${REPO_DIR}/.env"

# shellcheck source=scripts/registry-auth.sh
source "${SCRIPT_DIR}/registry-auth.sh"

if [ -f "$ENV_FILE" ]; then
    # Load local registry credentials without exporting unrelated shell state.
    set -a
    # shellcheck disable=SC1090
    source "$ENV_FILE"
    set +a
fi

ARG_USERNAME=""
ARG_PASSWORD=""
IMAGE_REFS=()

if [ "$#" -gt 0 ]; then
    if [ "$#" -ne 3 ]; then
        echo "Usage: $0 [image-ref] [username] [password]"
        echo "Alternatively set BOOTC_IMAGE_REFS plus registry-specific credentials in ${ENV_FILE}"
        exit 1
    fi

    IMAGE_REFS=("$1")
    ARG_USERNAME="$2"
    ARG_PASSWORD="$3"
else
    IMAGE_REFS_STR="${BOOTC_IMAGE_REFS:-${BOOTC_REGISTRY:-}}"
    if [ -z "$IMAGE_REFS_STR" ]; then
        echo "Usage: $0 [image-ref] [username] [password]"
        echo "Alternatively set BOOTC_IMAGE_REFS plus registry-specific credentials in ${ENV_FILE}"
        exit 1
    fi

    read -r -a IMAGE_REFS <<< "$IMAGE_REFS_STR"
fi

BASE_IMAGE_TAG="localhost/arch-bootc-base:latest"
FINAL_IMAGE_TAG="localhost/arch-bootc-hetzner:latest"
CHUNKED_IMAGE_TAG="localhost/arch-bootc-hetzner-chunked:latest"
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
CHUNKAH_VERSION="${CHUNKAH_VERSION:-v0.4.0}"

if [ -z "$BOOTC_VERSION" ] || [ "$BOOTC_VERSION" = "null" ]; then
    echo "ERROR: failed to resolve latest bootc release"
    exit 1
fi

if [ -z "$CHUNKAH_VERSION" ] || [ "$CHUNKAH_VERSION" = "null" ]; then
    echo "ERROR: failed to resolve latest chunkah release"
    exit 1
fi

CHUNKAH_IMAGE="quay.io/coreos/chunkah:${CHUNKAH_VERSION}"
CHUNKAH_ARGS="${CHUNKAH_ARGS:---max-layers 128}"
read -r -a CHUNKAH_ARGS_ARR <<< "$CHUNKAH_ARGS"

echo "## Using bootc ${BOOTC_VERSION}"
echo "## Using chunkah ${CHUNKAH_VERSION}"

for image_ref in "${IMAGE_REFS[@]}"; do
    registry_auth check "$image_ref" "$ARG_USERNAME" "$ARG_PASSWORD"
done

sudo -v

for image_ref in "${IMAGE_REFS[@]}"; do
    registry_auth podman-login "$image_ref" "$ARG_USERNAME" "$ARG_PASSWORD"
done

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
    build --config-str "$CHUNKAH_CONFIG_STR" "${CHUNKAH_ARGS_ARR[@]}" \
    | cat > "$CHUNKAH_ARCHIVE_PATH"
IMPORTED_IMAGE="$(sudo podman pull "oci-archive:${CHUNKAH_ARCHIVE_PATH}" | tail -n 1)"
sudo podman tag "$IMPORTED_IMAGE" "$CHUNKED_IMAGE_TAG"

for image_ref in "${IMAGE_REFS[@]}"; do
    target_image_tag="${image_ref}:latest"

    echo ""
    echo "## Pushing to $target_image_tag"
    sudo podman tag "$CHUNKED_IMAGE_TAG" "$target_image_tag"
    sudo podman push "$target_image_tag"
done

echo ""
echo "## Done. Image pushed to:"
for image_ref in "${IMAGE_REFS[@]}"; do
    echo "##   ${image_ref}:latest"
done
