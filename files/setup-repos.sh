#!/bin/bash
set -euo pipefail

# Setup coding repos with bare worktree pattern
# Run after SSH keys and GPG are configured

CODE_DIR="${HOME}/code/OSS"
mkdir -p "$CODE_DIR"

setup_harbor() {
    local dir="${CODE_DIR}/Harbr"
    if [ -f "${dir}/HEAD" ]; then
        echo "Harbor bare repo already exists at ${dir}, skipping init"
        echo "To re-fetch: cd ${dir} && git fetch --all"
        return 0
    fi

    echo "Setting up Harbor bare repo at ${dir}..."
    mkdir -p "$dir"
    git init --bare "$dir"
    cd "$dir"

    git remote add upstream https://github.com/goharbor/harbor.git
    git remote add bupd git@github.com:bupd/harbor.git
    git remote add next git@github.com:container-registry/harbor-next.git
    git remote add 8gcr git@github.com:container-registry/8gcr.git
    git remote add glab git@gitlab.com:8gears/container-registry/harbor.git

    echo "Fetching remotes (private repos need SSH keys)..."
    git fetch upstream || echo "WARN: failed to fetch upstream"
    git fetch bupd || echo "WARN: failed to fetch bupd"
    git fetch next || echo "WARN: failed to fetch next"
    git fetch 8gcr || echo "WARN: failed to fetch 8gcr"
    git fetch glab || echo "WARN: failed to fetch glab"

    local worktrees=(
        "upstream-main:upstream/main"
        "upstream-pr:upstream/main"
        "bupd-main:bupd/main"
        "bupd-pr:bupd/main"
        "next-next:next/next"
        "next-pr:next/next"
        "8gcr-next:8gcr/next"
        "8gcr-pr:8gcr/next"
    )

    for wt in "${worktrees[@]}"; do
        local name="${wt%%:*}"
        local ref="${wt##*:}"
        if git rev-parse --verify "$ref" >/dev/null 2>&1; then
            git worktree add "$name" "$ref" 2>/dev/null || echo "WARN: worktree $name already exists or failed"
        else
            echo "SKIP: ref $ref not available, skipping worktree $name"
        fi
    done

    echo "Harbor setup complete."
}

setup_satellite() {
    local dir="${CODE_DIR}/harborSatellite"
    if [ -f "${dir}/HEAD" ]; then
        echo "Satellite bare repo already exists at ${dir}, skipping init"
        echo "To re-fetch: cd ${dir} && git fetch --all"
        return 0
    fi

    echo "Setting up Harbor Satellite bare repo at ${dir}..."
    mkdir -p "$dir"
    git init --bare "$dir"
    cd "$dir"

    git remote add origin git@github.com:bupd/harbor-satellite.git
    git remote add upstream https://github.com/container-registry/harbor-satellite.git

    echo "Fetching remotes..."
    git fetch origin || echo "WARN: failed to fetch origin"
    git fetch upstream || echo "WARN: failed to fetch upstream"

    local ref=""
    if git rev-parse --verify "origin/main" >/dev/null 2>&1; then
        ref="origin/main"
    elif git rev-parse --verify "upstream/main" >/dev/null 2>&1; then
        ref="upstream/main"
    fi

    if [ -n "$ref" ]; then
        git worktree add "${CODE_DIR}/satellite" "$ref" 2>/dev/null || echo "WARN: satellite worktree already exists or failed"
        git worktree add "${CODE_DIR}/satellite-PR" "$ref" 2>/dev/null || echo "WARN: satellite-PR worktree already exists or failed"
    else
        echo "SKIP: no main ref available for satellite worktrees"
    fi

    echo "Satellite setup complete."
}

setup_harbor_cli() {
    local dir="${CODE_DIR}/harbor-cli"
    if [ -f "${dir}/HEAD" ]; then
        echo "Harbor CLI bare repo already exists at ${dir}, skipping init"
        echo "To re-fetch: cd ${dir} && git fetch --all"
        return 0
    fi

    echo "Setting up Harbor CLI bare repo at ${dir}..."
    mkdir -p "$dir"
    git init --bare "$dir"
    cd "$dir"

    git remote add upstream https://github.com/goharbor/harbor-cli.git
    git remote add origin git@github.com:bupd/harbor-cli.git

    echo "Fetching remotes..."
    git fetch upstream || echo "WARN: failed to fetch upstream"
    git fetch origin || echo "WARN: failed to fetch origin"

    local worktrees=(
        "upstream-main:upstream/main"
        "upstream-pr:upstream/main"
        "origin-main:origin/main"
        "origin-pr:origin/main"
    )

    for wt in "${worktrees[@]}"; do
        local name="${wt%%:*}"
        local ref="${wt##*:}"
        if git rev-parse --verify "$ref" >/dev/null 2>&1; then
            git worktree add "$name" "$ref" 2>/dev/null || echo "WARN: worktree $name already exists or failed"
        else
            echo "SKIP: ref $ref not available, skipping worktree $name"
        fi
    done

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
