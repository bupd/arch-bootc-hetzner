ARG BASE_IMAGE=ghcr.io/bootcrew/arch-bootc:latest
FROM ${BASE_IMAGE}

# Core server + dev packages
RUN --mount=type=tmpfs,dst=/tmp --mount=type=cache,dst=/usr/lib/sysimage/cache/pacman \
    pacman -Syu --noconfirm \
    openssh \
    sudo \
    vim \
    neovim \
    fastfetch \
    htop \
    btop \
    curl \
    wget \
    git \
    github-cli \
    mosh \
    tmux \
    zsh \
    bind \
    bind-tools \
    stow \
    fzf \
    ripgrep \
    fd \
    jq \
    go \
    gcc \
    make \
    unzip \
    gnupg \
    rsync \
    net-tools \
    iproute2 \
    traceroute \
    tailscale \
    qemu-guest-agent \
    ufw \
    grub \
    less \
    lazygit \
    skopeo \
    crane \
    podman-docker \
    podman-compose \
    kubectl \
    helm \
    k9s \
    yq \
    gopls \
    python \
    lua \
    luarocks \
    tree \
    lsof \
    man-db \
    base-devel \
    nodejs \
    npm \
    qemu-full \
    && pacman -S --clean --noconfirm

# Rebuild initramfs if pacman -Syu updated the kernel
RUN KDIR=$(find /usr/lib/modules -maxdepth 1 -type d -name '[0-9]*' | sort -V | tail -1) && \
    if [ ! -f "$KDIR/initramfs.img" ]; then \
        dracut --force "$KDIR/initramfs.img"; \
    fi

# k3s binary (downloaded during build)
RUN K3S_VERSION=$(curl -sfL https://update.k3s.io/v1-release/channels | jq -r '.data[] | select(.id=="stable") | .latest') && \
    curl -sfL -o /usr/bin/k3s "https://github.com/k3s-io/k3s/releases/download/$(echo "$K3S_VERSION" | sed 's/+/%2B/g')/k3s" && \
    chmod +x /usr/bin/k3s && \
    ln -sf /usr/bin/k3s /usr/bin/crictl && \
    ln -sf /usr/bin/k3s /usr/bin/ctr

# k3s systemd service
COPY files/k3s.service /usr/lib/systemd/system/k3s.service
COPY files/20-ethernet.network /usr/lib/systemd/network/20-ethernet.network
COPY files/90-k3s-network.conf /usr/lib/sysctl.d/90-k3s-network.conf

# ufw firewall - lockdown for public cloud
# Configure rules at build time; ufw enable requires iptables/kernel so
# we set ENABLED=yes and let systemd start it at boot
RUN ufw default deny incoming && \
    ufw default allow outgoing && \
    ufw allow ssh && \
    ufw allow 60000:61000/udp && \
    ufw allow in on tailscale0 && \
    ufw allow from 10.42.0.0/16 && \
    ufw allow from 10.43.0.0/16 && \
    ufw route allow from 10.42.0.0/16 && \
    ufw route allow to 10.42.0.0/16 && \
    ufw allow 41641/udp && \
    sed -i 's/^ENABLED=no/ENABLED=yes/' /etc/ufw/ufw.conf

# ESP sync scripts
# Installed to /usr/bin/ so they survive bootc upgrades (not /usr/local/ which maps to /var/)
COPY files/bootc-sync-esp.sh /usr/bin/bootc-sync-esp
RUN chmod +x /usr/bin/bootc-sync-esp

# Systemd services
COPY files/bootc-sync-esp.service /usr/lib/systemd/system/bootc-sync-esp.service
COPY files/bootc-sync-esp-finalize.service /usr/lib/systemd/system/bootc-sync-esp-finalize.service
COPY files/unlock-root.service /usr/lib/systemd/system/unlock-root.service
COPY files/ensure-mosh-firewall.sh /usr/bin/ensure-mosh-firewall
COPY files/ensure-mosh-firewall.service /usr/lib/systemd/system/ensure-mosh-firewall.service
COPY files/ensure-homebrew.sh /usr/bin/ensure-homebrew
COPY files/ensure-homebrew.service /usr/lib/systemd/system/ensure-homebrew.service
COPY files/homebrew.sh /etc/profile.d/homebrew.sh
COPY files/homebrew.Brewfile /usr/share/arch-bootc-hetzner/homebrew/Brewfile
RUN chmod +x /usr/bin/ensure-mosh-firewall
RUN chmod +x /usr/bin/ensure-homebrew

# Enable services
RUN systemctl enable sshd systemd-networkd systemd-resolved systemd-timesyncd tailscaled qemu-guest-agent serial-getty@ttyS0 bootc-sync-esp bootc-sync-esp-finalize unlock-root ensure-mosh-firewall ensure-homebrew ufw k3s

# Timezone and locale
RUN ln -sf /usr/share/zoneinfo/UTC /etc/localtime && \
    echo "en_US.UTF-8 UTF-8" > /etc/locale.gen && \
    locale-gen && \
    echo "LANG=en_US.UTF-8" > /etc/locale.conf

# Root password for emergency mode debugging (SSH still key-only)
# Use pre-hashed password (fixed salt) so ostree 3-way merge sees no diff across upgrades
RUN echo 'root:$6$bootcfixedsalt$LwmtTY8517vfslOJEBz1DYm5j2cNOixrdSjmPAmBKuCbKiiMnYKWEg5HzhSDoCcINliaxFgnhDwu9eInNmZWL/' | chpasswd -e

# Create user bupd with zsh
RUN useradd -m -G wheel -s /bin/zsh bupd && \
    echo "%wheel ALL=(ALL:ALL) NOPASSWD: ALL" > /etc/sudoers.d/wheel

# yay (AUR helper)
RUN --mount=type=tmpfs,dst=/tmp \
    git clone https://aur.archlinux.org/yay-bin.git /tmp/yay-bin && \
    chown -R bupd:bupd /tmp/yay-bin && \
    runuser -u bupd -- bash -c "cd /tmp/yay-bin && makepkg --noconfirm" && \
    pacman -U --noconfirm /tmp/yay-bin/*.pkg.tar.zst && \
    runuser -u bupd -- yay -S --noconfirm oras

# SSH config - key-based auth only
RUN mkdir -p /etc/ssh/sshd_config.d && \
    printf 'PermitRootLogin no\nPasswordAuthentication no\nPubkeyAuthentication yes\nAllowUsers bupd\n' \
    > /etc/ssh/sshd_config.d/10-hetzner.conf

# SSH authorized key for bupd
RUN mkdir -p /var/home/bupd/.ssh && chmod 700 /var/home/bupd/.ssh && \
    echo "ssh-rsa AAAAB3NzaC1yc2EAAAADAQABAAABgQDgOxVumFr4SNyhIXl5dfCYlZBON3EApcxrcBq3wvR/3BuY1jqJtmlppNffht6qmbAVOnJvJCxfQuWc5ju8O9/GSorVq+1qFmiIjIJv8hnqxed2BbHqko7jB1fgG3aDFUN6UhySYF2fBEcKWbAZEntOEuWo/ZrJyM2a/ktVd6aZrKghZ8HpN+PnX73ubYSTCrNUiAnDOssFJs6hpuPbAGUcTmG9E48kGKmbzBCRnxDbWotafwLj9PmTRT3e1TABRljd+UYnVkAmqXWFqEV12rMOZgPz/Lw6oKzrHdCUs1a325zpaek8Ffe3pzZtHIYERrft4pdTtnnaZQwoSxVkWaLvnBeuB1xqmDsGlF1xWNmMBbOanWZcwLIWkaVUaS/dvOju9xWGmOhhMjeUoMQodlPF+epwS5Iop2atm/uWzsGJBeZCGC/Yvcm8qgXo8EOWhHWjqopzVVr892QXrtwvOf6O+/7iVgYTtvoeNh9dAbiYbqFaJvLjIMOQ7UfzHtaO9Gc=" \
    > /var/home/bupd/.ssh/authorized_keys && \
    chmod 600 /var/home/bupd/.ssh/authorized_keys && \
    chown -R bupd:bupd /var/home/bupd/.ssh && \
    mkdir -p /var/home/bupd/code/OSS && chown -R bupd:bupd /var/home/bupd/code

# Repo setup script (bare worktrees for Harbor, Harbor CLI, and Harbor Satellite)
COPY files/setup-repos.sh /usr/bin/setup-repos
RUN chmod +x /usr/bin/setup-repos

# Bun (install to /usr/ so it survives bootc upgrades)
RUN BUN_INSTALL=/usr curl -fsSL https://bun.sh/install | bash

# Claude Code (native binary)
RUN curl -fsSL https://claude.ai/install.sh | bash && \
    cp ~/.local/bin/claude /usr/bin/claude

# OpenAI Codex CLI
RUN npm install -g --prefix /usr @openai/codex

# Lima (direct download, no homebrew needed)
RUN --mount=type=tmpfs,dst=/tmp \
    LIMA_VERSION=$(curl -sfL https://api.github.com/repos/lima-vm/lima/releases/latest | jq -r .tag_name) && \
    curl -sfL -o /tmp/lima.tar.gz "https://github.com/lima-vm/lima/releases/download/${LIMA_VERSION}/lima-${LIMA_VERSION#v}-Linux-x86_64.tar.gz" && \
    tar -xzf /tmp/lima.tar.gz -C /usr/

# Git config
RUN printf '[user]\n\tname = bupd\n\temail = bupdprasanth@gmail.com\n\tsigningkey = EFD822952819E418\n[core]\n\teditor = nvim\n[pull]\n\trebase = true\n[merge]\n\ttool = nvimdiff\n[diff]\n\ttool = nvimdiff\n\tcolorMoved = default\n[rerere]\n\tenabled = true\n\tautoUpdate = true\n[commit]\n\tgpgsign = true\n[tag]\n\tgpgsign = true\n[gpg]\n\tprogram = gpg\n' \
    > /var/home/bupd/.gitconfig && \
    chown bupd:bupd /var/home/bupd/.gitconfig

# Clone and stow dotfiles
# Pre-create agent config dirs as real dirs so stow merges into them (not dir-level symlinks)
RUN mkdir -p /var/home/bupd/.claude/skills /var/home/bupd/.codex/skills && \
    git clone https://github.com/bupd/dotfiles.git /var/home/bupd/dotfiles && \
    cd /var/home/bupd/dotfiles && \
    stow -d /var/home/bupd/dotfiles -t /var/home/bupd . && \
    chown -R bupd:bupd /var/home/bupd

# Claude Code + Codex: settings, agents, skills (self-contained in bootc repo)
COPY files/claude-settings.json /var/home/bupd/.claude/settings.json
COPY files/dot-claude/agents/ /var/home/bupd/.claude/agents/
COPY files/dot-claude/skills/ /var/home/bupd/.claude/skills/
COPY files/dot-agents/skills/ /var/home/bupd/.codex/skills/
RUN cd /var/home/bupd/.claude/skills && \
    ln -sf ../../.codex/skills/find-skills find-skills && \
    ln -sf ../../.codex/skills/go go && \
    ln -sf ../../.codex/skills/helm-chart helm-chart && \
    ln -sf ../../.codex/skills/remotion-best-practices remotion-best-practices && \
    ln -sf ../../.codex/skills/systemd systemd && \
    ln -sf ../../.codex/skills/taskfile taskfile && \
    mkdir -p /var/home/bupd/.agents && \
    ln -sfn ../.codex/skills /var/home/bupd/.agents/skills && \
    chown -R bupd:bupd /var/home/bupd/.claude /var/home/bupd/.codex /var/home/bupd/.agents

# Server-specific sessionizer (overrides dotfiles version with correct paths)
COPY files/sessionizer /var/home/bupd/sessionizer
RUN chmod +x /var/home/bupd/sessionizer && \
    mkdir -p /var/home/bupd/.local/bin && \
    ln -sf /var/home/bupd/sessionizer /var/home/bupd/.local/bin/sessionizer && \
    chown -R bupd:bupd /var/home/bupd/.local

# Zshrc (not managed by stow per .stow-local-ignore)
COPY files/zshrc /var/home/bupd/.zshrc
RUN chown bupd:bupd /var/home/bupd/.zshrc /var/home/bupd/sessionizer

LABEL containers.bootc 1
RUN bootc container lint
