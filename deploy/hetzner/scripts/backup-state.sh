#!/bin/bash
set -euo pipefail

# ─── Workspace Backup ─────────────────────────────────────────
# Backs up OpenClaw runtime state from /mnt/kb/runtime/ to the
# openclaw-state/ directory in the user's private repo.
#
# Runs on a systemd timer (daily).
# Pushes to the 'backup' branch, rebased on 'main'.
# ─────────────────────────────────────────────────────────────────

REPO_DIR="/root/openclaw-state-repo"
STATE_DIR="openclaw-state"
RUNTIME_DIR="/mnt/kb/runtime"
KB_DIR="/mnt/kb/user_knowledge_base"
AGENTS_DIR="/mnt/kb/agents"
SKILLS_DIR="/mnt/kb/skills"
BRANCH="backup"
LOG_TAG="[backup-state]"

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

# Create or switch to backup branch
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
mkdir -p "$STATE_DIR/workspace/knowledge_base"
mkdir -p "$STATE_DIR/agents"
mkdir -p "$STATE_DIR/skills"

# For backup, we want everything, but skip node_modules and big temp files that are irrelevant
rsync -a --delete \
    --exclude 'secrets/' \
    --exclude '*/.git/' \
    --exclude '*/.git/*' \
    --exclude 'node_modules/' \
    --exclude '.npm/' \
    --exclude '.cache/' \
    --exclude 'tmp/' \
    --exclude 'CachedData/' \
    --exclude 'Cache/' \
    --exclude 'GPUCache/' \
    --exclude 'blob_storage/' \
    --exclude 'chromium-profile/' \
    "$RUNTIME_DIR/" "$STATE_DIR/"

# Backup the other mounted directories to their expected locations in the state folder
rsync -a --delete "$KB_DIR/" "$STATE_DIR/workspace/knowledge_base/"
rsync -a --delete "$AGENTS_DIR/" "$STATE_DIR/agents/"
rsync -a --delete "$SKILLS_DIR/" "$STATE_DIR/skills/"

# ─── Commit and push ──────────────────────────────────────────
# Force add files that might be ignored in .gitignore
git add --force "$STATE_DIR/"

if git diff --cached --quiet; then
    log "No changes to commit."
    exit 0
fi

TIMESTAMP=$(date '+%Y-%m-%d %H:%M:%S %Z')
HOSTNAME=$(hostname)
git commit -m "backup: $HOSTNAME @ $TIMESTAMP" --quiet

log "Pushing to origin/$BRANCH..."
if git push origin "$BRANCH" --force-with-lease --quiet 2>/dev/null; then
    log "✅ Backup complete."
else
    log "WARN: Push failed (force-with-lease rejected). Will retry next cycle."
fi
