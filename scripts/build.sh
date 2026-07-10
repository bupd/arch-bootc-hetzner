#!/bin/bash
set -euo pipefail

# Build arch-bootc images and push to one or more container registries.
#
# Usage:
#   ./scripts/build.sh [image-ref] [username] [password]
#
# Example:
#   ./scripts/build.sh
#   ./scripts/build.sh ghcr.io/bupd/bootc bupd "$(gh auth token)"

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

GITHUB_API_TOKEN="${GITHUB_TOKEN:-${GH_TOKEN:-${GHCR_TOKEN:-}}}"
if [ -z "$GITHUB_API_TOKEN" ] && [ -n "$ARG_PASSWORD" ] && [ "$(registry_host "${IMAGE_REFS[0]}")" = "ghcr.io" ]; then
    GITHUB_API_TOKEN="$ARG_PASSWORD"
fi
if [ -z "$GITHUB_API_TOKEN" ] && command -v gh >/dev/null 2>&1; then
    GITHUB_API_TOKEN="$(gh auth token 2>/dev/null || true)"
fi

BASE_IMAGE_TAG="localhost/arch-bootc-base:latest"
FINAL_IMAGE_TAG="localhost/arch-bootc-hetzner:latest"
CHUNKED_IMAGE_TAG="localhost/arch-bootc-hetzner-chunked:latest"
IMAGE_TAG="${BOOTC_IMAGE_TAG:-latest}"
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
    local -a curl_args=(-fsSL)

    if [ -n "$GITHUB_API_TOKEN" ]; then
        curl_args+=(-H "Authorization: Bearer ${GITHUB_API_TOKEN}")
    fi

    curl "${curl_args[@]}" "https://api.github.com/repos/${repo}/releases/latest" | jq -r '.tag_name'
}

BOOTC_VERSION="$(github_latest_release_tag bootc-dev/bootc)"
CHUNKAH_VERSION="${CHUNKAH_VERSION:-v0.6.0}"

if [ -z "$BOOTC_VERSION" ] || [ "$BOOTC_VERSION" = "null" ]; then
    echo "ERROR: failed to resolve latest bootc release"
    exit 1
fi

if [ -z "$CHUNKAH_VERSION" ] || [ "$CHUNKAH_VERSION" = "null" ]; then
    echo "ERROR: failed to resolve latest chunkah release"
    exit 1
fi

CHUNKAH_IMAGE="${CHUNKAH_IMAGE:-quay.io/coreos/chunkah:${CHUNKAH_VERSION}}"
CHUNKAH_ARGS="${CHUNKAH_ARGS:---max-layers 128 --prune /sysroot/ --label ostree.commit- --label ostree.final-diffid-}"
read -r -a CHUNKAH_ARGS_ARR <<< "$CHUNKAH_ARGS"

echo "## Using bootc ${BOOTC_VERSION}"
echo "## Using chunkah ${CHUNKAH_VERSION}"
echo "## Publishing image tag ${IMAGE_TAG}"

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
IMAGE_CREATED="${IMAGE_CREATED:-$(date -u +%Y-%m-%dT%H:%M:%SZ)}"
IMAGE_REVISION="${IMAGE_REVISION:-$(git -C "$REPO_DIR" rev-parse HEAD 2>/dev/null || echo unknown)}"
IMAGE_VERSION="${IMAGE_VERSION:-${IMAGE_TAG}}"
sudo podman build --network=host \
    --build-arg "BASE_IMAGE=${BASE_IMAGE_TAG}" \
    --build-arg "IMAGE_CREATED=${IMAGE_CREATED}" \
    --build-arg "IMAGE_REVISION=${IMAGE_REVISION}" \
    --build-arg "IMAGE_VERSION=${IMAGE_VERSION}" \
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
    target_image_tag="${image_ref}:${IMAGE_TAG}"

    echo ""
    echo "## Pushing to $target_image_tag"
    sudo podman tag "$CHUNKED_IMAGE_TAG" "$target_image_tag"
    sudo podman push "$target_image_tag"
done

echo ""
echo "## Done. Image pushed to:"
for image_ref in "${IMAGE_REFS[@]}"; do
    echo "##   ${image_ref}:${IMAGE_TAG}"
done
