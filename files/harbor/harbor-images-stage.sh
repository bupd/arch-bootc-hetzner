#!/bin/bash
set -euo pipefail
mkdir -p /var/lib/rancher/k3s/agent/images
cp /usr/share/k3s-images/*.tar /var/lib/rancher/k3s/agent/images/
cp /usr/share/k3s-images/*.zst /var/lib/rancher/k3s/agent/images/ 2>/dev/null || true
touch /var/lib/rancher/k3s/agent/images/.staged

# k3s auto-detects systemd on the host and sets SystemdCgroup=true in the
# generated containerd config. With cgroupfs-format kubelet cgroup paths
# (/k8s.io/...) this causes a format mismatch in runc. Force cgroupfs mode:
# it works correctly in both rootless (private cgroupns is writable) and
# rootful (real root has direct cgroup fs access) container modes.
mkdir -p /var/lib/rancher/k3s/agent/etc/containerd/config-v3.toml.d
cat > /var/lib/rancher/k3s/agent/etc/containerd/config-v3.toml.d/cgroup-override.toml << 'EOF'
[plugins."io.containerd.cri.v1.runtime".containerd.runtimes.runc.options]
  SystemdCgroup = false
EOF
