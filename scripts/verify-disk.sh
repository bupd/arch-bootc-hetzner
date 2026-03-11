#!/bin/bash
set -euo pipefail
shopt -s nullglob

# Verify a bootc disk is correctly set up before rebooting.
# Run this from Hetzner rescue mode.
#
# Usage:
#   ./verify-disk.sh [disk]
#
# Example:
#   ./verify-disk.sh /dev/sda

DISK="${1:-/dev/sda}"
ERRORS=0

check() {
    local desc="$1"
    local result="$2"
    if [ -n "$result" ]; then
        echo "[OK]   $desc"
    else
        echo "[FAIL] $desc"
        ERRORS=$((ERRORS + 1))
    fi
}

echo "## Verifying bootc disk: $DISK"
echo ""

# Find partitions
EFI_PART=$(fdisk -l "$DISK" 2>/dev/null | grep "EFI System" | awk '{print $1}')
ROOT_PART=$(fdisk -l "$DISK" 2>/dev/null | grep "Linux root" | awk '{print $1}')

check "EFI partition found" "$EFI_PART"
check "Root partition found" "$ROOT_PART"

if [ -z "$ROOT_PART" ] || [ -z "$EFI_PART" ]; then
    echo ""
    echo "## Cannot continue without both partitions"
    exit 1
fi

# Mount
mount "$ROOT_PART" /mnt 2>/dev/null || true
mount "$EFI_PART" /mnt/boot/efi 2>/dev/null || true

echo ""
echo "## EFI Bootloader"
check "BOOTX64.EFI exists" "$(ls /mnt/boot/efi/EFI/BOOT/BOOTX64.EFI 2>/dev/null)"

echo ""
echo "## Loader Config"
check "loader.conf exists" "$(ls /mnt/boot/efi/loader/loader.conf 2>/dev/null)"
ENTRY_FILES=(/mnt/boot/efi/loader/entries/*.conf)
DEFAULT_ENTRY=""
if [ -f /mnt/boot/efi/loader/loader.conf ]; then
    DEFAULT_ENTRY=$(awk '/^default / {print $2; exit}' /mnt/boot/efi/loader/loader.conf)
fi

if [ ${#ENTRY_FILES[@]} -gt 0 ]; then
    echo "[OK]   at least one boot entry exists"
else
    echo "[FAIL] at least one boot entry exists"
    ERRORS=$((ERRORS + 1))
fi

if [ -n "$DEFAULT_ENTRY" ] && [ -f "/mnt/boot/efi/loader/entries/$DEFAULT_ENTRY" ]; then
    echo ""
    echo "## Default Boot Entry"
    cat "/mnt/boot/efi/loader/entries/$DEFAULT_ENTRY"
elif [ ${#ENTRY_FILES[@]} -gt 0 ]; then
    echo ""
    echo "## First Boot Entry"
    cat "${ENTRY_FILES[0]}"
fi

echo ""
echo "## Kernel and Initramfs on ESP"
check "Kernel on ESP" "$(find /mnt/boot/efi -name 'vmlinuz-*' 2>/dev/null)"
check "Initramfs on ESP" "$(find /mnt/boot/efi -name 'initramfs-*' 2>/dev/null)"

echo ""
echo "## Root UUID"
ROOT_UUID=$(blkid -s UUID -o value "$ROOT_PART")
ENTRY_SOURCE=""
if [ -n "$DEFAULT_ENTRY" ] && [ -f "/mnt/boot/efi/loader/entries/$DEFAULT_ENTRY" ]; then
    ENTRY_SOURCE="/mnt/boot/efi/loader/entries/$DEFAULT_ENTRY"
elif [ ${#ENTRY_FILES[@]} -gt 0 ]; then
    ENTRY_SOURCE="${ENTRY_FILES[0]}"
fi
ENTRY_UUID=$(grep -oP 'UUID=\K[^ ]+' "$ENTRY_SOURCE" 2>/dev/null || true)
echo "   Disk:  $ROOT_UUID"
echo "   Entry: $ENTRY_UUID"
if [ "$ROOT_UUID" = "$ENTRY_UUID" ]; then
    echo "[OK]   UUIDs match"
else
    echo "[FAIL] UUIDs do NOT match"
    ERRORS=$((ERRORS + 1))
fi

echo ""
echo "## Ostree Deployment"
DEPLOY=$(ls -d /mnt/ostree/deploy/default/deploy/*.0 2>/dev/null | head -1)
check "Deployment exists" "$DEPLOY"

if [ -n "$DEPLOY" ]; then
    echo ""
    echo "## SSH Access"
    check "sshd enabled" "$(ls $DEPLOY/etc/systemd/system/multi-user.target.wants/sshd.service 2>/dev/null)"
    check "authorized_keys exists" "$(ls "$DEPLOY"/var/home/*/.ssh/authorized_keys 2>/dev/null)"

    echo ""
    echo "## Network"
    check "networkd enabled" "$(find $DEPLOY/etc/systemd -name '*networkd.service' 2>/dev/null)"
fi

echo ""
echo "## Partition Size"
df -h "$ROOT_PART" | tail -1

# Cleanup
umount /mnt/boot/efi 2>/dev/null || true
umount /mnt 2>/dev/null || true

echo ""
if [ $ERRORS -eq 0 ]; then
    echo "## ALL CHECKS PASSED - safe to reboot"
else
    echo "## $ERRORS CHECK(S) FAILED - fix before rebooting"
    exit 1
fi
