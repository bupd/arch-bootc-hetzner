#!/bin/bash
# Freeze a running harbor-seed into a committed snapshot image
# Run harbor-run.sh first, then call this once Harbor is ready
set -euo pipefail

SRC=${1:-harbor-seed}
TAG=${2:-harbor-frozen:v2.14.3}

echo "Checking Harbor is healthy before freeze..."
curl -sf http://127.0.0.1:30080/api/v2.0/ping >/dev/null || { echo "Harbor not responding on :30080"; exit 1; }

echo "Committing ${SRC} → ${TAG}..."
sudo podman commit "$SRC" "$TAG"

echo "Stopping seed container..."
sudo podman stop "$SRC"
sudo podman rm "$SRC"

echo ""
echo "Frozen image ready: ${TAG}"
echo "Run it: sudo podman run --privileged --systemd=always --device /dev/null:/dev/kmsg -p 30080:30080 ${TAG} /sbin/init"
