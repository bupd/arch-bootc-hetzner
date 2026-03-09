# Arch Linux Bootc for Hetzner Cloud

Bootable container (bootc) image for running Arch Linux on Hetzner Cloud VPS servers. Uses [bootcrew/arch-bootc](https://github.com/bootcrew/arch-bootc) as the base image with systemd-boot.

## What is bootc?

[bootc](https://github.com/bootc-dev/bootc) is an image-based Linux system. Instead of managing packages on a live system, you build an OCI container image and deploy it as the OS. Updates are atomic: `bootc upgrade` stages a new image, reboot switches to it, and the previous image stays as a rollback.

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
```

This takes 20-40 minutes (compiles bootc from source with Rust).

### 3. Generate bootable disk image

```sh
# Generate disk image, compress, and push to registry via oras
./scripts/generate-disk.sh <registry/repo> <username> <password>
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

# Install k3s (optional)
curl -sfL https://get.k3s.io | sh -

# Import GPG key (for git signing)
gpg --import your-private-key.asc

# Change hostname
sudo hostnamectl set-hostname <new-name>
```

## Future Upgrades

After updating the Containerfile:

```sh
# Rebuild and push
./scripts/build.sh <registry/repo> <username> <password>

# On the server
sudo bootc upgrade
sudo reboot
```

The previous image remains as a rollback entry in systemd-boot.

## Known Issues

### EFI bootloader not installed by bootc

`bootc install to-disk --bootloader systemd` places the systemd-boot binary and loader config on the root partition, but UEFI firmware looks for them on the EFI System Partition (ESP). The `flash-disk.sh` script handles this automatically by copying `BOOTX64.EFI`, loader entries, kernel, and initramfs to the ESP.

See: [bootc-dev/bootc#865](https://github.com/bootc-dev/bootc/issues/865)

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
- Consider adding `qemu-guest-agent` to the Containerfile for Hetzner integration (graceful shutdown, IP reporting)

## What's Included

### Packages
openssh, sudo, vim, neovim, htop, btop, curl, wget, git, tmux, zsh, stow, fzf, ripgrep, fd, jq, go, gcc, make, unzip, nodejs, npm, gnupg, rsync, net-tools, iproute2, traceroute, tailscale

### Services (enabled)
sshd, systemd-networkd, systemd-resolved, systemd-timesyncd, tailscaled

### Security
- Root login disabled
- Password auth disabled (key-only SSH)
- Wheel group with passwordless sudo

## Credits

- [bootcrew/arch-bootc](https://github.com/bootcrew/arch-bootc) for the base Arch bootc image
- [bootc](https://github.com/bootc-dev/bootc) for image-based Linux
- [oras](https://oras.land/) for OCI artifact distribution
- [Yorick Peterse's blog post](https://yorickpeterse.com/articles/self-hosting-my-websites-using-bootable-containers/) for inspiration
