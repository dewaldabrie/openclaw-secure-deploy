#!/bin/bash
set -euo pipefail

# ─── Workspace Git Sync ─────────────────────────────────────────
# Syncs OpenClaw runtime state from /mnt/kb/runtime/ to the
# openclaw-state/ directory in the user's private repo.
#
# Runs on a systemd timer (every 30 minutes).
# Pushes to the 'auto-sync' branch, rebased on 'main'.
# ─────────────────────────────────────────────────────────────────

REPO_DIR="/root/openclaw-state-repo"
STATE_DIR="openclaw-state"
RUNTIME_DIR="/mnt/kb/runtime"
BRANCH="auto-sync"
LOG_TAG="[sync-state]"

log() { echo "$LOG_TAG $(date '+%Y-%m-%d %H:%M:%S') $*"; }

# ─── Pre-flight checks ─────────────────────────────────────────
if [ ! -d "$REPO_DIR/.git" ]; then
    log "ERROR: Repo not cloned at $REPO_DIR. Run setup.sh first."
    exit 1
fi

if [ ! -d "$RUNTIME_DIR" ]; then
    log "ERROR: Runtime directory $RUNTIME_DIR not found."
    exit 1
fi

cd "$REPO_DIR"

# ─── Fetch and rebase on main ──────────────────────────────────
log "Fetching origin..."
git fetch origin main --quiet 2>/dev/null || true

# Create or switch to auto-sync branch
if ! git rev-parse --verify "$BRANCH" &>/dev/null; then
    log "Creating $BRANCH branch from origin/main..."
    git checkout -b "$BRANCH" origin/main --quiet
else
    git checkout "$BRANCH" --quiet 2>/dev/null || true
fi

# Rebase on main to incorporate deploy/config changes
log "Rebasing $BRANCH on origin/main..."
if ! git rebase origin/main --quiet 2>/dev/null; then
    log "WARN: Rebase conflict. Resetting to origin/main..."
    git rebase --abort 2>/dev/null || true
    git reset --hard origin/main --quiet
fi

# ─── Rsync runtime state ──────────────────────────────────────
log "Syncing runtime state..."
mkdir -p "$STATE_DIR"

rsync -a --delete \
    --exclude 'secrets/' \
    --exclude '*/.git/' \
    --exclude '*/.git/*' \
    --exclude '.mitmproxy/' \
    --exclude 'proxy/traffic.log' \
    --exclude 'proxy/.mitmproxy/' \
    --exclude 'node_modules/' \
    --exclude '.npm/' \
    --exclude '.cache/' \
    --exclude 'tmp/' \
    --exclude 'logs/' \
    --exclude '*.sock' \
    --exclude '*.pid' \
    --exclude '*.log' \
    --exclude '*.bkp*' \
    --exclude '*.bak*' \
    --exclude 'CachedData/' \
    --exclude 'Cache/' \
    --exclude 'GPUCache/' \
    --exclude 'blob_storage/' \
    --exclude 'chromium-profile/' \
    "$RUNTIME_DIR/" "$STATE_DIR/"

# ─── Commit and push ──────────────────────────────────────────
git add "$STATE_DIR/"

if git diff --cached --quiet; then
    log "No changes to commit."
    exit 0
fi

TIMESTAMP=$(date '+%Y-%m-%d %H:%M:%S %Z')
HOSTNAME=$(hostname)
git commit -m "auto-sync: $HOSTNAME @ $TIMESTAMP" --quiet

log "Pushing to origin/$BRANCH..."
if git push origin "$BRANCH" --force-with-lease --quiet 2>/dev/null; then
    log "✅ Sync complete."
else
    log "WARN: Push failed (force-with-lease rejected). Will retry next cycle."
fi
