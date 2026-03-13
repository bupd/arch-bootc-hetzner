# Arch Linux Bootable Container (bootc) for Hetzner Cloud

Deploy **Arch Linux** as an **immutable, image-based OS** on **Hetzner Cloud VPS** servers using [bootc](https://github.com/bootc-dev/bootc) (bootable containers). Build your OS as an OCI container image, flash it to a Hetzner server, and manage upgrades atomically with built-in rollback.

Based on [bootcrew/arch-bootc](https://github.com/bootcrew/arch-bootc) with systemd-boot.

## Why Use This?

- **Immutable infrastructure** - your server OS is defined in a `Containerfile`, versioned in git, and reproducible
- **Atomic upgrades** - `bootc upgrade` stages a new image; reboot switches to it; previous image stays as rollback
- **No manual package management** - packages are baked into the image at build time
- **Hetzner-ready** - scripts handle UEFI boot, EFI partition setup, disk flashing from rescue mode, and network config
- **OCI-native** - the OS image is a standard container image stored in any OCI registry

## Features

- Arch Linux running as a bootable OCI container on Hetzner Cloud
- Automated disk image generation and flashing via rescue mode
- systemd-boot with automatic kernel and EFI sync
- Atomic OS upgrades with rollback via `bootc upgrade`
- k3s (lightweight Kubernetes) with systemd service
- Tailscale VPN integration
- UFW firewall with cloud-safe defaults
- SSH key-only authentication, root login disabled
- Pre-configured dev environment (Go, Node.js, Neovim, tmux, zsh)

## Architecture

```
Containerfile.base      # bootcrew/arch-bootc base (compiles bootc from source)
Containerfile           # Your custom image (packages, users, dotfiles, SSH keys)
scripts/
  build.sh              # Build and push container image to registry
  generate-disk.sh      # Generate bootable.img and push via oras
  flash-disk.sh         # Flash disk from Hetzner rescue mode (handles EFI fix)
  verify-disk.sh        # Verify disk setup before rebooting
  post-boot.sh          # Post-boot verification and setup
```

## Quick Start

### 1. Fork and customize

Fork this repo and edit the `Containerfile`:
- Replace the SSH public key with yours
- Change the username from `bupd` to yours
- Update the git config
- Add/remove packages as needed
- Update or remove the dotfiles clone

### 2. Build

```sh
# One-liner: build base + custom image and push to registry
./scripts/build.sh <registry/repo> <username> <password>

# Example
./scripts/build.sh registry.example.com/myuser/bootc myuser mypassword

# Or store BOOTC_REGISTRY / BOOTC_USERNAME / BOOTC_PASSWORD in .env
cp .env.example .env
./scripts/build.sh
```

This takes 20-40 minutes (compiles bootc from source with Rust).

### 3. Generate bootable disk image

```sh
# Generate disk image, compress, and push to registry via oras
./scripts/generate-disk.sh <registry/repo> <username> <password>

# Or reuse BOOTC_* values from .env
./scripts/generate-disk.sh
```

The compressed disk image (~1.7 GiB) gets pushed as `<registry>:disk-latest`.

### 4. Flash to Hetzner server

From the Hetzner Cloud Console:
1. Enable rescue mode (Rescue tab, choose linux64)
2. Power Cycle the server (Power tab)
3. SSH into rescue: `ssh root@<server-ip>`

Then run the flash script:

```sh
curl -sL https://raw.githubusercontent.com/bupd/arch-bootc-hetzner/main/scripts/flash-disk.sh -o flash-disk.sh
chmod +x flash-disk.sh
./flash-disk.sh <registry/repo> <username> <password>
```

This script:
- Pulls the compressed disk image via oras
- Writes it to `/dev/sda` with dd
- Resizes the root partition to fill the disk
- Installs systemd-boot EFI binary (fixes a known bootc issue)
- Copies kernel, initramfs, and loader config to the ESP

### 5. Verify before rebooting

```sh
curl -sL https://raw.githubusercontent.com/bupd/arch-bootc-hetzner/main/scripts/verify-disk.sh -o verify-disk.sh
chmod +x verify-disk.sh
./verify-disk.sh
```

Checks: EFI bootloader, loader config, kernel/initramfs, UUID match, SSH keys, networkd, partition size.

### 6. Reboot into Arch

1. Disable rescue mode (Hetzner Console, Rescue tab)
2. Power Cycle (Power tab)
3. Wait 1-2 minutes
4. `ssh <your-user>@<server-ip>`

### 7. Post-boot setup

```sh
./scripts/post-boot.sh
```

Then manually:
```sh
# Re-authenticate tailscale
sudo tailscale up

# Import GPG key (for git signing)
gpg --import your-private-key.asc

# Change hostname
sudo hostnamectl set-hostname <new-name>
```

## Upgrades

After updating the Containerfile:

```sh
# Rebuild and push
./scripts/build.sh <registry/repo> <username> <password>

# On the server
sudo bootc upgrade
sudo reboot
```

The image now keeps the ESP in sync twice:
- on every successful boot (`bootc-sync-esp.service`) as a repair path
- on shutdown after `ostree-finalize-staged.service` (`bootc-sync-esp-finalize.service`) so staged upgrades copy the correct loader state before the next boot

The previous image remains as a rollback entry in systemd-boot.

## Known Issues

### EFI bootloader not installed by bootc

`bootc install to-disk --bootloader systemd` places the systemd-boot binary and loader config on the root partition, but UEFI firmware looks for them on the EFI System Partition (ESP). The `flash-disk.sh` script handles this automatically by copying `BOOTX64.EFI`, loader entries, kernel, and initramfs to the ESP.

See: [bootc-dev/bootc#865](https://github.com/bootc-dev/bootc/issues/865)

### Why upgrades could previously fail to boot

OSTree staged deployments delay bootloader updates until shutdown in `ostree-finalize-staged.service`. Syncing the ESP immediately after `bootc upgrade` is therefore too early and can leave the ESP with stale loader entries or the wrong default entry. This repo now syncs the ESP after OSTree finalization and preserves the exact `loader.conf` generated under `/boot` instead of guessing a default entry.

See:
- [OSTree staged deployments](https://ostreedev.github.io/ostree/deployment/)
- [OSTree bootloader flow](https://ostreedev.github.io/ostree/bootloaders/)

## Recover a broken Hetzner host after a bad upgrade

If the machine drops into emergency mode with an error like `couldn't find specified OSTree root`, repair the ESP from Hetzner rescue mode instead of reflashing:

```sh
curl -sL https://raw.githubusercontent.com/bupd/arch-bootc-hetzner/main/scripts/repair-esp.sh -o repair-esp.sh
chmod +x repair-esp.sh
./repair-esp.sh /dev/sda
./verify-disk.sh /dev/sda
reboot
```

This rebuilds the ESP from the installed root filesystem's active `/boot/loader*` state.

### Arch is not officially supported by bootc

bootc officially targets Fedora/CentOS. Arch support is community-maintained via [bootcrew/arch-bootc](https://github.com/bootcrew/arch-bootc). Key workarounds:
- Uses systemd-boot instead of GRUB (Arch GRUB lacks BLS support)
- Builds bootc from source (AUR package is incomplete)
- Relocates `/var` to `/usr/lib/sysimage` for pacman compatibility

### Hetzner-specific notes

- Hetzner Cloud VPS uses UEFI (not legacy BIOS)
- Default disk is `/dev/sda` (305 GiB QEMU HARDDISK)
- Rescue mode is Debian-based with oras/zstd available via apt
- VNC console (Hetzner Console button) is the escape hatch if SSH breaks
- `qemu-guest-agent` is included for Hetzner integration (graceful shutdown, IP reporting)

## Included Software

### Packages
openssh, sudo, vim, neovim, fastfetch, htop, btop, curl, wget, git, tmux, zsh, stow, fzf, ripgrep, fd, jq, go, gcc, make, unzip, nodejs, npm, gnupg, rsync, net-tools, iproute2, traceroute, tailscale, podman, kubectl, helm, k9s, k3s

### Services (enabled)
sshd, systemd-networkd, systemd-resolved, systemd-timesyncd, tailscaled, qemu-guest-agent, ufw, k3s, bootc-sync-esp

### Developer CLIs
- Claude Code (`claude`)
- OpenAI Codex CLI (`codex`)
- GitHub CLI (`gh`)
- fastfetch, btop

### Mosh + tmux
- `mosh-server` is installed in the image via the `mosh` package
- UFW allows UDP `60000:61000` for mosh sessions
- Client-side usage: connect with `mosh <user>@<server-ip>` instead of plain SSH when you want a roaming session
- Client-side usage: start tmux after login with `tmux new -As main`

### Security
- Root login disabled
- Password auth disabled (key-only SSH)
- Wheel group with passwordless sudo
- UFW firewall enabled

## Credits

- [bootcrew/arch-bootc](https://github.com/bootcrew/arch-bootc) for the base Arch bootc image
- [bootc](https://github.com/bootc-dev/bootc) for image-based Linux
- [oras](https://oras.land/) for OCI artifact distribution
- [Yorick Peterse's blog post](https://yorickpeterse.com/articles/self-hosting-my-websites-using-bootable-containers/) for inspiration

## License

[MIT](LICENSE)
