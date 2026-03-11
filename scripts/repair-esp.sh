#!/bin/bash
set -euo pipefail
shopt -s nullglob

# Repair a bootc/systemd-boot ESP from rescue mode without reflashing.
#
# Usage:
#   ./repair-esp.sh [disk]
#
# Example:
#   ./repair-esp.sh /dev/sda

DISK="${1:-/dev/sda}"
ROOT_MNT="/mnt"
ESP_MNT="/mnt/boot/efi"

log() { echo "repair-esp: $*"; }

EFI_PART=$(fdisk -l "$DISK" 2>/dev/null | awk '/EFI System/ {print $1; exit}')
ROOT_PART=$(fdisk -l "$DISK" 2>/dev/null | awk '/Linux root/ {print $1; exit}')

if [ -z "$ROOT_PART" ] || [ -z "$EFI_PART" ]; then
    log "could not detect both root and EFI partitions on $DISK"
    exit 1
fi

mount "$ROOT_PART" "$ROOT_MNT"
mount "$EFI_PART" "$ESP_MNT"

cleanup() {
    umount "$ESP_MNT" 2>/dev/null || true
    umount "$ROOT_MNT" 2>/dev/null || true
}
trap cleanup EXIT

DEPLOY=$(ls -dt "$ROOT_MNT"/ostree/deploy/default/deploy/*.0 2>/dev/null | head -1 || true)
if [ -z "$DEPLOY" ]; then
    log "no ostree deployment found under $ROOT_MNT"
    exit 1
fi

LOADER_DIR=""
if [ -L "$ROOT_MNT/boot/loader" ]; then
    LOADER_DIR=$(readlink -f "$ROOT_MNT/boot/loader")
fi
if [ -z "$LOADER_DIR" ] || [ ! -d "$LOADER_DIR/entries" ]; then
    for candidate in "$ROOT_MNT"/boot/loader.1 "$ROOT_MNT"/boot/loader.0; do
        if [ -d "$candidate/entries" ]; then
            LOADER_DIR="$candidate"
            break
        fi
    done
fi

if [ -z "$LOADER_DIR" ] || [ ! -d "$LOADER_DIR/entries" ]; then
    log "could not find an active loader directory"
    exit 1
fi

mkdir -p "$ESP_MNT/EFI/BOOT" "$ESP_MNT/EFI/systemd" "$ESP_MNT/loader/entries"
cp "$DEPLOY/usr/lib/systemd/boot/efi/systemd-bootx64.efi" "$ESP_MNT/EFI/BOOT/BOOTX64.EFI"
cp "$DEPLOY/usr/lib/systemd/boot/efi/systemd-bootx64.efi" "$ESP_MNT/EFI/systemd/systemd-bootx64.efi"

rm -f "$ESP_MNT/loader/entries/"*.conf "$ESP_MNT/loader/loader.conf"
cp "$LOADER_DIR/entries/"*.conf "$ESP_MNT/loader/entries/"
sed -i 's|/boot/ostree/|/ostree/|g' "$ESP_MNT/loader/entries/"*.conf
if [ -f "$ESP_MNT/loader/entries/ostree-2.conf" ]; then
    printf 'default ostree-2.conf\ntimeout 5\n' > "$ESP_MNT/loader/loader.conf"
else
    first_entry=$(basename "$(ls -1 "$ESP_MNT/loader/entries/"*.conf | head -1)")
    printf 'default %s\ntimeout 5\n' "$first_entry" > "$ESP_MNT/loader/loader.conf"
fi

rm -rf "$ESP_MNT/ostree"
for ostree_dir in "$ROOT_MNT"/boot/ostree/default-*; do
    [ -d "$ostree_dir" ] || continue
    dest_dir="$ESP_MNT/ostree/$(basename "$ostree_dir")"
    mkdir -p "$dest_dir"

    kernels=("$ostree_dir"/vmlinuz-*)
    if [ ${#kernels[@]} -gt 0 ]; then
        cp "${kernels[@]}" "$dest_dir/"
    fi

    initramfs=("$ostree_dir"/initramfs-*)
    if [ ${#initramfs[@]} -gt 0 ]; then
        cp "${initramfs[@]}" "$dest_dir/"
    fi
done

sync
log "ESP repaired from loader $(basename "$LOADER_DIR") on $DISK"
