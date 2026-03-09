## Arch Linux Bootc - Hetzner Server Migration Plan

This plan builds a bootable Arch Linux image with bootc, pushes it to a registry, and guides the OS switch on a Hetzner Cloud VPS.

The server is currently running Debian 13 (Trixie) on a CPX41 (8 vCPU, 16GB RAM, 300GB disk) at Hetzner Nuremberg.

## Phase 1: Build the bootc image

### Step 1: Clone the repo

```sh
git clone https://github.com/bupd/arch-bootc-hetzner.git ~/arch-bootc-hetzner
cd ~/arch-bootc-hetzner
```

### Step 2: Login to Harbor registry

```sh
sudo podman login registry.goharbor.io -u "robot_bupd+bootc" -p "Harbor12345"
```

### Step 3: Build the base image

This compiles bootc from source with Rust. Takes 20-40 minutes.

```sh
sudo podman build -f Containerfile.base -t arch-bootc:latest .
```

If the build fails due to memory, add swap:
```sh
sudo fallocate -l 4G /swapfile && sudo chmod 600 /swapfile && sudo mkswap /swapfile && sudo swapon /swapfile
```

### Step 4: Build the hetzner image

Tag the local base so the Containerfile FROM resolves:
```sh
sudo podman tag arch-bootc:latest ghcr.io/bootcrew/arch-bootc:latest
```

Build the final image:
```sh
sudo podman build -f Containerfile -t registry.goharbor.io/bupd/bootc:latest .
```

### Step 5: Push container image to Harbor

```sh
sudo podman push registry.goharbor.io/bupd/bootc:latest
```

## Phase 2: Generate bootable disk image

### Step 6: Generate bootable.img

Create a 20GB bootable disk image using bootc install:
```sh
sudo fallocate -l 20G ~/arch-bootc-hetzner/bootable.img

sudo podman run \
    --rm --privileged --pid=host \
    -v /var/lib/containers:/var/lib/containers \
    -v /etc/containers:/etc/containers \
    -v /dev:/dev \
    -v ~/arch-bootc-hetzner:/data \
    registry.goharbor.io/bupd/bootc:latest \
    bootc install to-disk \
    --composefs-backend \
    --via-loopback /data/bootable.img \
    --filesystem ext4 \
    --wipe \
    --bootloader systemd
```

This creates a raw disk image that can be written directly to a server's disk.

### Step 7: Install oras and push bootable.img to registry

Install oras CLI:
```sh
VERSION="1.2.2"
curl -LO "https://github.com/oras-project/oras/releases/download/v${VERSION}/oras_${VERSION}_linux_amd64.tar.gz"
tar -xzf oras_${VERSION}_linux_amd64.tar.gz
sudo mv oras /usr/local/bin/
rm oras_${VERSION}_linux_amd64.tar.gz
```

Login to Harbor with oras:
```sh
oras login registry.goharbor.io -u "robot_bupd+bootc" -p "Harbor12345"
```

Compress and push the bootable.img:
```sh
zstd ~/arch-bootc-hetzner/bootable.img -o ~/arch-bootc-hetzner/bootable.img.zst
oras push registry.goharbor.io/bupd/bootc:disk-latest \
    ~/arch-bootc-hetzner/bootable.img.zst:application/octet-stream
```

This allows anyone with registry access to pull the bootable image later:
```sh
oras pull registry.goharbor.io/bupd/bootc:disk-latest
zstd -d bootable.img.zst
```

## Phase 3: Flash the server (requires user action)

### Step 8: TELL THE USER

At this point, stop and tell the user:

> The bootable.img has been built and pushed to the registry. To switch the Hetzner server to Arch Linux, you need to do the following manually through the Hetzner Cloud Console (cloud.hetzner.com):
>
> 1. Go to your server "debian-16gb-nbg1-1" in Hetzner Cloud Console
> 2. Go to the "Rescue" tab
> 3. Enable rescue mode (choose linux64) and note the root password shown
> 4. Go to the "Power" tab and click "Power Cycle" (hard reboot into rescue)
> 5. Once rescue is booted, come back and tell me the rescue root password so I can SSH in, or SSH into rescue yourself: `ssh root@128.140.12.238`
>
> IMPORTANT: Before doing this, make sure you have backed up anything critical from the server. The disk will be overwritten.
>
> Your k3s data in /var/lib/rancher will be LOST. If you need it, back it up first:
> ```
> ssh bupd@100.68.136.39 "sudo tar czf /tmp/k3s-backup.tar.gz /var/lib/rancher /etc/rancher"
> scp bupd@100.68.136.39:/tmp/k3s-backup.tar.gz ./
> ```
>
> Your tailscale state will also need re-authentication after the switch.

Wait for the user to confirm rescue mode is active before proceeding.

### Step 9: Write bootable.img to disk from rescue mode

Once in rescue mode (SSH as root to the server's public IP 128.140.12.238):

Install oras in rescue:
```sh
curl -LO "https://github.com/oras-project/oras/releases/download/v1.2.2/oras_1.2.2_linux_amd64.tar.gz"
tar -xzf oras_1.2.2_linux_amd64.tar.gz
```

Login and pull the disk image:
```sh
./oras login registry.goharbor.io -u "robot_bupd+bootc" -p "Harbor12345"
./oras pull registry.goharbor.io/bupd/bootc:disk-latest
```

Decompress:
```sh
apt update && apt install -y zstd
zstd -d bootable.img.zst
```

Identify the main disk (should be /dev/sda on Hetzner Cloud):
```sh
lsblk
```

Write the image to disk:
```sh
dd if=bootable.img of=/dev/sda bs=4M status=progress
sync
```

The bootable.img is 20GB but the disk is 300GB. After writing, grow the partition and filesystem:
```sh
parted /dev/sda resizepart 3 100%
e2fsck -f /dev/sda3
resize2fs /dev/sda3
```

Note: the partition number (3) may differ. Check with `lsblk` or `fdisk -l /dev/sda` after dd to find the root partition.

### Step 10: Disable rescue mode and reboot

TELL THE USER:

> The disk image has been written. Now:
> 1. Go back to Hetzner Cloud Console
> 2. Go to the "Rescue" tab and disable rescue mode
> 3. Go to the "Power" tab and click "Power Cycle"
> The server will now boot into Arch Linux.

Wait for the user to confirm they've done this.

## Phase 4: Post-boot setup

### Step 11: Verify the new system

After reboot, SSH in (may take 1-2 minutes to come up):
```sh
ssh bupd@128.140.12.238
```

If SSH fails, the user needs to use Hetzner VNC console to debug. TELL THE USER:

> If SSH doesn't connect within 3 minutes, go to Hetzner Cloud Console, click on your server, and use the Console (VNC) button to see what's happening on the screen. Look for boot errors or network issues. Report back what you see.

Once connected, verify:
```sh
cat /etc/os-release
bootc status
systemctl status sshd
systemctl status systemd-networkd
systemctl status tailscaled
```

### Step 12: Re-authenticate tailscale

```sh
sudo tailscale up
```

This will print a URL. TELL THE USER:

> Tailscale needs re-authentication. Open this URL in your browser to authorize the device. You may want to remove the old "hetzner" device from your Tailscale admin console first.

### Step 13: Reinstall k3s

```sh
curl -sfL https://get.k3s.io | sh -
```

If the user has a k3s backup, restore it:
```sh
sudo systemctl stop k3s
sudo tar xzf /path/to/k3s-backup.tar.gz -C /
sudo systemctl start k3s
```

Verify:
```sh
sudo k3s kubectl get nodes
sudo k3s kubectl get pods -A
```

### Step 14: Install additional tools

Claude Code (if the user wants it):
```sh
# Install npm if not already available, then:
npm install -g @anthropic-ai/claude-code
```

### Step 15: Set up bootc upgrades

For future image updates, the workflow becomes:
1. Update the Containerfile in the repo
2. Rebuild and push: `sudo podman build -t registry.goharbor.io/bupd/bootc:latest . && sudo podman push registry.goharbor.io/bupd/bootc:latest`
3. On the server: `sudo bootc upgrade && sudo reboot`

The previous image stays as a rollback. If something breaks, select the previous boot entry from systemd-boot.

## Misc

- The Hetzner server public IP is 128.140.12.238, tailscale IP is 100.68.136.39
- The server hostname is debian-16gb-nbg1-1 (should be changed post-migration with `hostnamectl set-hostname arch-hetzner` or similar)
- The Hetzner Cloud VNC console is the escape hatch if SSH and tailscale both break
- qemu-guest-agent is on the current Debian install but NOT in the Arch image. Consider adding it to the Containerfile if Hetzner features depend on it (graceful shutdown, IP reporting)
- GPG keys are NOT in the image. The user will need to import their private GPG key manually for git commit signing
- Zinit and p10k will auto-install on first zsh login (downloads from GitHub)
- The .zshrc is embedded in the Containerfile, NOT managed by stow. Future updates to zshrc need to update both the dotfiles repo and the Containerfile
- If the dd or partition resize fails, the user can always re-enable Hetzner rescue mode and retry. Rescue mode is non-destructive to the rescue environment.
