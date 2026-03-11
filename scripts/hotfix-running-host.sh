#!/bin/bash
set -euo pipefail

# Apply the ESP sync fix to a currently running bootc host before the next
# upgrade. Run this on the target host as root:
#
#   sudo bash hotfix-running-host.sh

TMPDIR="/tmp/bootc-fix"
REPO_RAW="https://raw.githubusercontent.com/bupd/arch-bootc-hetzner/main"
ESP_DEV="${ESP_DEV:-/dev/sda2}"

mkdir -p "$TMPDIR"
cd "$TMPDIR"

curl -fsSLo bootc-sync-esp.sh "$REPO_RAW/files/bootc-sync-esp.sh"
curl -fsSLo bootc-sync-esp.service "$REPO_RAW/files/bootc-sync-esp.service"
curl -fsSLo bootc-sync-esp-finalize.service "$REPO_RAW/files/bootc-sync-esp-finalize.service"

ostree admin unlock --hotfix

install -Dm755 bootc-sync-esp.sh /usr/bin/bootc-sync-esp
install -Dm644 bootc-sync-esp.service /usr/lib/systemd/system/bootc-sync-esp.service
install -Dm644 bootc-sync-esp-finalize.service /usr/lib/systemd/system/bootc-sync-esp-finalize.service

rm -f /usr/bin/bootc-wrapper
if [ -e /usr/bin/bootc.real ]; then
    ln -sf /usr/bin/bootc.real /usr/bin/bootc
fi

systemctl daemon-reload
systemctl enable bootc-sync-esp.service bootc-sync-esp-finalize.service

mkdir -p /boot/efi
mountpoint -q /boot/efi || mount "$ESP_DEV" /boot/efi

/usr/bin/bootc-sync-esp

echo '=== /boot/efi ==='
findmnt /boot/efi
echo '=== loader.conf ==='
cat /boot/efi/loader/loader.conf
echo '=== entries ==='
for f in /boot/efi/loader/entries/*.conf; do
    echo "----- $f -----"
    sed -n '1,120p' "$f"
done
echo '=== service ==='
systemctl status bootc-sync-esp.service --no-pager || true
