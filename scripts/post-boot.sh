#!/bin/bash
set -euo pipefail

# Post-boot verification script for a freshly flashed bootc Arch Linux system.
# Run this after the first successful boot.
# This script is read-only and must not install or modify anything.
#
# Usage:
#   ./post-boot.sh

TARGET_USER="${SUDO_USER:-${USER:-bupd}}"
TARGET_HOME="$(getent passwd "$TARGET_USER" | cut -d: -f6)"
if [ -z "${TARGET_HOME:-}" ]; then
    TARGET_HOME="$HOME"
fi

echo "## Verifying system"
echo ""

echo "OS:"
cat /etc/os-release | grep PRETTY_NAME

echo ""
echo "Bootc status:"
if command -v /usr/bin/bootc > /dev/null 2>&1; then
    sudo /usr/bin/bootc status 2>/dev/null || echo "bootc installed but status requires elevated access"
else
    echo "bootc not installed"
fi

echo ""
echo "## Tooling"
for tool in fastfetch btop claude codex; do
    if command -v "$tool" > /dev/null 2>&1; then
        echo "  $tool: installed"
    else
        echo "  $tool: MISSING"
    fi
done

echo ""
echo "## Agent config"
echo "User: $TARGET_USER"
echo "Home: $TARGET_HOME"

check_any() {
    local label="$1"
    shift
    local path
    for path in "$@"; do
        if [ -e "$path" ]; then
            echo "  $label: present ($path)"
            return 0
        fi
    done
    echo "  $label: MISSING"
}

check_any "claude settings" \
    "$TARGET_HOME/.claude/settings.json" \
    "$TARGET_HOME/dotfiles/.claude/settings.local.json"
check_any "claude agents" \
    "$TARGET_HOME/.claude/agents" \
    "$TARGET_HOME/dotfiles/bootc/files/dot-claude/agents"
check_any "claude skills" \
    "$TARGET_HOME/.claude/skills" \
    "$TARGET_HOME/dotfiles/bootc/files/dot-claude/skills"
check_any "codex skills" \
    "$TARGET_HOME/.codex/skills" \
    "$TARGET_HOME/.agents/skills" \
    "$TARGET_HOME/dotfiles/bootc/files/dot-agents/skills"
check_any "AGENTS.md" \
    "$TARGET_HOME/AGENTS.md" \
    "$TARGET_HOME/dotfiles/AGENTS.md"
check_any "CLAUDE.md" \
    "$TARGET_HOME/CLAUDE.md" \
    "$TARGET_HOME/dotfiles/CLAUDE.md"
check_any "kube config" \
    "$TARGET_HOME/.kube/config"

echo ""
echo "Services:"
for svc in sshd systemd-networkd systemd-resolved systemd-timesyncd tailscaled; do
    status=$(systemctl is-active "$svc" 2>/dev/null || echo "inactive")
    echo "  $svc: $status"
done

echo ""
echo "Network:"
ip -4 addr show scope global | grep inet || echo "No global IPv4 addresses found"

echo ""
echo "Disk:"
df -h / | tail -1

# Tailscale
echo ""
echo "## Tailscale"
if systemctl is-active tailscaled > /dev/null 2>&1; then
    if tailscale status > /dev/null 2>&1; then
        echo "Tailscale is connected"
        tailscale status | awk 'NR <= 5 { print }'
    else
        echo "Tailscale is running but not authenticated"
    fi
else
    echo "Tailscale is not running"
fi

# Hostname
echo ""
echo "## Hostname"
echo "Current: $(hostname)"
echo "To change: sudo hostnamectl set-hostname <new-name>"

# k3s
echo ""
echo "## k3s"
if command -v k3s &> /dev/null; then
    echo "k3s is installed"
    sudo k3s kubectl get nodes 2>/dev/null || echo "k3s is not running"
else
    echo "k3s is not installed"
fi

# GPG
echo ""
echo "## GPG"
if gpg --list-secret-keys 2>/dev/null | grep -q "sec"; then
    echo "GPG keys found"
else
    echo "No GPG secret keys found"
fi

## Coding repos
echo ""
echo "## Coding repos"
echo "setup-repos remains a separate manual step after SSH keys are configured"

echo ""
echo "## Done"
