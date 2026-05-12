#!/bin/bash
set -euo pipefail

# Generate a bootable disk image from the container image and optionally
# push it to a registry using oras.
#
# Usage:
#   ./scripts/generate-disk.sh [image-ref] [username] [password]
#
# Example:
#   ./scripts/generate-disk.sh
#   ./scripts/generate-disk.sh ghcr.io/bupd/bootc your-github-username your-ghcr-token

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_DIR="$(dirname "$SCRIPT_DIR")"
ENV_FILE="${REPO_DIR}/.env"

# shellcheck source=scripts/registry-auth.sh
source "${SCRIPT_DIR}/registry-auth.sh"

if [ -f "$ENV_FILE" ]; then
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

OUTPUT_DIR="$REPO_DIR"
IMG="$OUTPUT_DIR/bootable.img"
DISK_SIZE="${BOOTC_DISK_SIZE:-20G}"
SOURCE_IMAGE_REF="${BOOTC_SOURCE_IMAGE_REF:-${IMAGE_REFS[0]}}"
PUSH_IMAGE_REFS=()

for image_ref in "${IMAGE_REFS[@]}"; do
    if registry_has_credentials "$image_ref" "$ARG_USERNAME" "$ARG_PASSWORD"; then
        PUSH_IMAGE_REFS+=("$image_ref")
    fi
done

if [ "${#PUSH_IMAGE_REFS[@]}" -gt 0 ] && [ "${#PUSH_IMAGE_REFS[@]}" -ne "${#IMAGE_REFS[@]}" ]; then
    for image_ref in "${IMAGE_REFS[@]}"; do
        registry_auth check "$image_ref" "$ARG_USERNAME" "$ARG_PASSWORD"
    done
fi

sudo -v

if registry_has_credentials "$SOURCE_IMAGE_REF" "$ARG_USERNAME" "$ARG_PASSWORD"; then
    registry_auth podman-login "$SOURCE_IMAGE_REF" "$ARG_USERNAME" "$ARG_PASSWORD"
fi

echo "## Creating ${DISK_SIZE} disk image"
if [ ! -e "$IMG" ]; then
    fallocate -l "$DISK_SIZE" "$IMG"
fi

echo ""
echo "## Running bootc install to-disk"
sudo podman run \
    --rm --privileged --pid=host --network=host \
    -v /var/lib/containers:/var/lib/containers \
    -v /etc/containers:/etc/containers \
    -v /dev:/dev \
    -v "$OUTPUT_DIR:/data" \
    "$SOURCE_IMAGE_REF:latest" \
    bootc install to-disk \
    --composefs-backend \
    --via-loopback /data/bootable.img \
    --filesystem ext4 \
    --wipe \
    --bootloader systemd

echo ""
echo "## Disk image created: $IMG"
ls -lh "$IMG"

# Push to registries with oras if credentials provided
if [ "${#PUSH_IMAGE_REFS[@]}" -gt 0 ]; then
    ORAS_VERSION="1.2.2"

    if ! command -v oras &> /dev/null; then
        echo ""
        echo "## Installing oras CLI"
        curl -sLO "https://github.com/oras-project/oras/releases/download/v${ORAS_VERSION}/oras_${ORAS_VERSION}_linux_amd64.tar.gz"
        tar -xzf "oras_${ORAS_VERSION}_linux_amd64.tar.gz" oras
        sudo mv oras /usr/local/bin/
        rm -f "oras_${ORAS_VERSION}_linux_amd64.tar.gz"
    fi

    echo ""
    echo "## Compressing disk image with zstd"
    zstd -f "$IMG" -o "$IMG.zst"
    ls -lh "$IMG.zst"

    for image_ref in "${PUSH_IMAGE_REFS[@]}"; do
        echo ""
        echo "## Pushing disk image to ${image_ref}:disk-latest"
        registry_auth oras-login "$image_ref" "$ARG_USERNAME" "$ARG_PASSWORD"
        (cd "$OUTPUT_DIR" && oras push "${image_ref}:disk-latest" "$(basename "$IMG").zst:application/octet-stream")
    done

    echo ""
    echo "## Cleaning up local files"
    rm -f "$IMG" "$IMG.zst"

    echo "## Done. Disk image pushed to:"
    for image_ref in "${PUSH_IMAGE_REFS[@]}"; do
        echo "##   ${image_ref}:disk-latest"
    done
else
    echo ""
    echo "## Skipping registry push (no credentials provided)"
    echo "## Disk image available at: $IMG"
fi
