#!/bin/bash
set -euo pipefail
export KUBECONFIG=/etc/rancher/k3s/k3s.yaml

log() { echo "[harbor-init] $*"; }

log "waiting for k3s API..."
until kubectl get nodes --no-headers 2>/dev/null | grep -q " Ready"; do
    sleep 5
done
log "k3s ready — node: $(kubectl get nodes --no-headers | awk '{print $1, $2}')"

CHART=$(find /usr/share/harbor/charts/ -name 'harbor-*.tgz' | head -1)
log "installing Harbor from ${CHART}..."

helm install harbor "$CHART" \
    --namespace harbor \
    --create-namespace \
    --values /usr/share/harbor/values.yaml \
    --wait \
    --timeout 10m

log "Harbor deployed"
log "  UI:       http://127.0.0.1:30080"
log "  Login:    admin / Harbor12345"
log ""
log "To create a frozen snapshot:"
log "  podman commit <container-name> harbor-frozen:v2.14.3"

touch /var/lib/harbor-deployed
