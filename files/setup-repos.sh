#!/bin/bash
set -euo pipefail

# Setup coding repos with bare worktree pattern
# Run after SSH keys and GPG are configured

CODE_DIR="${HOME}/code/OSS"
mkdir -p "$CODE_DIR"

ensure_bare_repo() {
    local dir="$1"

    if [ -f "${dir}/HEAD" ]; then
        return 1
    fi

    echo "Initializing bare repo at ${dir}..."
    mkdir -p "$dir"
    git init --bare "$dir" >/dev/null
    return 0
}

ensure_remote() {
    local name="$1"
    local url="$2"
    local current=""

    current="$(git remote get-url "$name" 2>/dev/null || true)"
    if [ -z "$current" ]; then
        git remote add "$name" "$url"
        echo "Added remote ${name} -> ${url}"
    elif [ "$current" != "$url" ]; then
        git remote set-url "$name" "$url"
        echo "Updated remote ${name} -> ${url}"
    else
        echo "Remote ${name} already configured"
    fi
}

ensure_worktree() {
    local name="$1"
    local ref="$2"

    if git rev-parse --verify "$ref" >/dev/null 2>&1; then
        git worktree add "$name" "$ref" 2>/dev/null || echo "WARN: worktree $name already exists or failed"
    else
        echo "SKIP: ref $ref not available, skipping worktree $name"
    fi
}

setup_harbor() {
    local dir="${CODE_DIR}/harbor"

    if [ -f "${dir}/HEAD" ]; then
        echo "Harbor bare repo already exists at ${dir}, leaving local repo untouched"
        return 0
    fi

    echo "Setting up Harbor bare repo at ${dir}..."
    ensure_bare_repo "$dir"
    cd "$dir"

    ensure_remote upstream https://github.com/goharbor/harbor
    ensure_remote bupd git@github.com:bupd/harbor.git
    ensure_remote next git@github.com:container-registry/harbor-next.git
    ensure_remote glab git@gitlab.com:8gears/container-registry/harbor.git
    ensure_remote 8gcr git@github.com:container-registry/8gcr.git

    echo "Fetching remotes (private repos need SSH keys)..."
    git fetch upstream || echo "WARN: failed to fetch upstream"
    git fetch bupd || echo "WARN: failed to fetch bupd"
    git fetch next || echo "WARN: failed to fetch next"
    git fetch 8gcr || echo "WARN: failed to fetch 8gcr"
    git fetch glab || echo "WARN: failed to fetch glab"

    ensure_worktree upstream-main upstream/main
    ensure_worktree upstream-pr upstream/main
    ensure_worktree bupd-main bupd/main
    ensure_worktree bupd-pr bupd/main
    ensure_worktree next-next next/next
    ensure_worktree next-pr next/next
    ensure_worktree 8gcr-next 8gcr/next
    ensure_worktree 8gcr-pr 8gcr/next

    echo "Harbor setup complete."
}

setup_satellite() {
    local dir="${CODE_DIR}/harbor-satellite"

    if [ -f "${dir}/HEAD" ]; then
        echo "Harbor Satellite bare repo already exists at ${dir}, leaving local repo untouched"
        return 0
    fi

    echo "Setting up Harbor Satellite bare repo at ${dir}..."
    ensure_bare_repo "$dir"
    cd "$dir"

    ensure_remote upstream git@github.com:container-registry/harbor-satellite.git
    ensure_remote origin git@github.com:bupd/harbor-satellite.git

    echo "Fetching remotes..."
    git fetch upstream || echo "WARN: failed to fetch upstream"
    git fetch origin || echo "WARN: failed to fetch origin"

    ensure_worktree upstream-main upstream/main
    ensure_worktree upstream-pr upstream/main
    ensure_worktree origin-main origin/main
    ensure_worktree origin-pr origin/main

    echo "Satellite setup complete."
}

setup_harbor_cli() {
    local dir="${CODE_DIR}/harbor-cli"

    if [ -f "${dir}/HEAD" ]; then
        echo "Harbor CLI bare repo already exists at ${dir}, leaving local repo untouched"
        return 0
    fi

    echo "Setting up Harbor CLI bare repo at ${dir}..."
    ensure_bare_repo "$dir"
    cd "$dir"

    ensure_remote upstream https://github.com/goharbor/harbor-cli.git
    ensure_remote origin git@github.com:bupd/harbor-cli.git

    echo "Fetching remotes..."
    git fetch upstream || echo "WARN: failed to fetch upstream"
    git fetch origin || echo "WARN: failed to fetch origin"

    ensure_worktree upstream-main upstream/main
    ensure_worktree upstream-pr upstream/main
    ensure_worktree origin-main origin/main
    ensure_worktree origin-pr origin/main

    echo "Harbor CLI setup complete."
}

echo "=== Setting up coding repos ==="
setup_harbor
echo ""
setup_harbor_cli
echo ""
setup_satellite
echo ""
echo "Done. Re-run after SSH keys are configured if any private remotes failed."
