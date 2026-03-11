#!/bin/bash
set -euo pipefail
shopt -s nullglob

ESP="/boot/efi"
BOOT="/boot"

log() { echo "bootc-sync-esp: $*"; }

find_loader_dir() {
    local loader_dir=""

    # OSTree rotates between loader.0 and loader.1 and exposes the active one
    # through /boot/loader.
    if [ -L "$BOOT/loader" ]; then
        loader_dir=$(readlink -f "$BOOT/loader")
    fi

    if [ -z "$loader_dir" ] || [ ! -d "$loader_dir/entries" ]; then
        for candidate in "$BOOT"/loader.1 "$BOOT"/loader.0; do
            if [ -d "$candidate/entries" ]; then
                loader_dir="$candidate"
                break
            fi
        done
    fi

    if [ -z "$loader_dir" ] || [ ! -d "$loader_dir/entries" ]; then
        log "no loader entries found under $BOOT"
        return 1
    fi

    printf '%s\n' "$loader_dir"
}

ensure_esp_mounted() {
    if mountpoint -q "$ESP"; then
        return 0
    fi

    local efi_part=""
    efi_part=$(blkid -t PARTLABEL="EFI System" -o device 2>/dev/null | head -1 || true)
    if [ -z "$efi_part" ]; then
        efi_part=$(blkid -t TYPE="vfat" -o device 2>/dev/null | head -1 || true)
    fi

    if [ -z "$efi_part" ]; then
        log "no EFI partition found"
        return 1
    fi

    mount "$efi_part" "$ESP"
}

sync_loader_tree() {
    local loader_dir="$1"
    local entry
    local entries=("$loader_dir"/entries/*.conf)
    local default_entry=""
    local existing_loader_conf=""

    if [ ${#entries[@]} -eq 0 ]; then
        log "no boot entries found in $loader_dir/entries"
        return 1
    fi

    if [ -f "$ESP/loader/loader.conf" ]; then
        existing_loader_conf=$(mktemp)
        cp "$ESP/loader/loader.conf" "$existing_loader_conf"
    fi

    mkdir -p "$ESP/loader/entries"
    rm -f "$ESP/loader/entries/"*.conf "$ESP/loader/loader.conf"
    cp "${entries[@]}" "$ESP/loader/entries/"

    for entry in "$ESP"/loader/entries/*.conf; do
        sed -i 's|/boot/ostree/|/ostree/|g' "$entry"
    done

    # Preserve an existing default if it still exists; otherwise prefer the
    # active deployment entry (ostree-2.conf on this image layout).
    if [ -n "$existing_loader_conf" ] && [ -f "$existing_loader_conf" ]; then
        default_entry=$(awk '/^default / {print $2; exit}' "$existing_loader_conf")
    fi
    if [ -z "$default_entry" ] || [ ! -f "$ESP/loader/entries/$default_entry" ]; then
        if [ -f "$ESP/loader/entries/ostree-2.conf" ]; then
            default_entry="ostree-2.conf"
        else
            default_entry=$(basename "${entries[0]}")
        fi
    fi

    printf 'default %s\ntimeout 5\n' "$default_entry" > "$ESP/loader/loader.conf"

    if [ -n "$existing_loader_conf" ]; then
        rm -f "$existing_loader_conf"
    fi
}

sync_efi_binaries() {
    if [ ! -f /usr/lib/systemd/boot/efi/systemd-bootx64.efi ]; then
        return 0
    fi

    mkdir -p "$ESP/EFI/BOOT" "$ESP/EFI/systemd"
    cp /usr/lib/systemd/boot/efi/systemd-bootx64.efi "$ESP/EFI/BOOT/BOOTX64.EFI"
    cp /usr/lib/systemd/boot/efi/systemd-bootx64.efi "$ESP/EFI/systemd/systemd-bootx64.efi"
}

sync_ostree_payloads() {
    local ostree_dir
    local dest
    local kernels
    local initramfs

    rm -rf "$ESP/ostree"

    for ostree_dir in "$BOOT"/ostree/default-*; do
        [ -d "$ostree_dir" ] || continue
        dest="$ESP/ostree/$(basename "$ostree_dir")"
        mkdir -p "$dest"

        kernels=("$ostree_dir"/vmlinuz-*)
        if [ ${#kernels[@]} -gt 0 ]; then
            cp "${kernels[@]}" "$dest/"
        fi

        initramfs=("$ostree_dir"/initramfs-*)
        if [ ${#initramfs[@]} -gt 0 ]; then
            cp "${initramfs[@]}" "$dest/"
        fi
    done
}

ensure_esp_mounted
loader_dir=$(find_loader_dir)
log "active loader: $loader_dir"

sync_efi_binaries
sync_loader_tree "$loader_dir"
sync_ostree_payloads

log "ESP synced (loader: $(basename "$loader_dir"))"
