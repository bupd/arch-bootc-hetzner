#!/bin/bash
# Run Harbor bootc container
# Usage:
#   ./scripts/harbor-run.sh                      # run harbor-dev:latest
#   ./scripts/harbor-run.sh harbor-frozen:v2.14.3 # run frozen image
set -euo pipefail

IMAGE=${1:-harbor-dev:latest}
NAME=${2:-harbor-seed}

echo "Starting ${IMAGE} as '${NAME}'..."

sudo podman run -d \
  --name "$NAME" \
  --privileged \
  --systemd=always \
  --device /dev/null:/dev/kmsg \
  -p 30080:30080 \
  "$IMAGE" \
  /sbin/init

echo "Waiting for Harbor UI at http://127.0.0.1:30080 ..."
echo "(watch: podman exec ${NAME} journalctl -u harbor-init -f)"
until curl -sf http://127.0.0.1:30080/api/v2.0/ping >/dev/null 2>&1; do
  sleep 5
done

echo ""
echo "Harbor is UP"
echo "  UI:    http://127.0.0.1:30080"
echo "  Login: admin / Harbor12345"
