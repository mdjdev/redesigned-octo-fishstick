#!/usr/bin/env bash

################################################################################
# Git Remote Sync Hook
################################################################################
# Description:
#   Ensures local repository is synchronized with remote before allowing push.
#   Designed to run before gitwatch pushes changes, preventing divergence.
#
# Usage:
#   Called automatically by gitwatch via -c flag, or manually before push
#
# Environment Variables:
#   GIT_DIR             Git metadata location (default: current repo)
#   REMOTE              Remote name (default: origin)
#   BRANCH              Branch name (default: main)
#   REMOTE_URL          Remote repository URL (required if remote doesn't exist)
#   SSH_KEY             Path to SSH private key (default: /run/secrets/id_ed25519_github)
#
# Exit Codes:
#   0   Success - safe to proceed with push
#   1   Error - cannot proceed, manual intervention required
################################################################################

set -euo pipefail

################################################################################
# Configuration
################################################################################

: "${REPO_DIR:=/mnt/repo}"
: "${GIT_DIR:=/mnt/.git}"
: "${REMOTE:=origin}"
: "${BRANCH:=main}"
: "${REMOTE_URL:=git@github.com:mdjdev/redesigned-octo-fishstick.git}"
: "${SSH_KEY:=/run/secrets/id_ed25519_github}"

# Export Git environment variables to use separated directory layout
export GIT_DIR="$GIT_DIR"
export GIT_WORK_TREE="$REPO_DIR"

################################################################################
# SSH Validation
################################################################################

# Verify SSH key exists
if [ ! -f "$SSH_KEY" ]; then
  echo "Error: SSH key not found at $SSH_KEY"
  exit 1
fi

# Ensure SSH key has restrictive permissions
if [ "$(stat -c %a -- "$SSH_KEY")" != 600 ]; then 
  echo "Error: SSH key at $SSH_KEY has mismatching permissions or ownership."
  echo "Hint: ensure the key is owned by the running user and has mode 600, or supply a valid secret."
  exit 1
fi

# Probe GitHub SSH auth (non-interactive)
set +e
ssh -T git@github.com \
    -i "$SSH_KEY" \
    -o BatchMode=yes \
    -o StrictHostKeyChecking=accept-new \
    -F /dev/null \
    2>/dev/null
status=$?
set -e

if [ "$status" -eq 255 ]; then
  echo "SSH authentication to GitHub failed."
  exit 1
elif [ "$status" -ne 1 ]; then
  echo "Unexpected SSH status: $status"
  exit 1
fi

################################################################################
# Repository Initialization
################################################################################

# Initialize empty repository if not already initialized
if [ ! -d "$GIT_DIR/objects" ]; then
  git init -b "$BRANCH"
fi

################################################################################
# Git Configuration
################################################################################

# Set identity for commits
git config user.name "gitwatch"
git config user.email "gitwatch@dsm.local"

# Configure SSH command to use specific key
git config core.sshCommand "ssh -i $SSH_KEY -o StrictHostKeyChecking=accept-new -F /dev/null"

# Disable GPG signing (non-interactive environment)
git config commit.gpgsign false

# Safety: only allow fast-forward pushes
git config push.ff only

# Automatically prune deleted remote branches
git config fetch.prune true

################################################################################
# Remote Setup
################################################################################

# Ensure remote exists/URL is correct
if git remote get-url "$REMOTE" >/dev/null 2>&1; then
  git remote set-url "$REMOTE" "$REMOTE_URL"
else
  git remote add "$REMOTE" "$REMOTE_URL"
fi

################################################################################
# Sync Check
################################################################################

# Always fetch first; if this fails, we cannot reason about safety.
if ! git fetch "$REMOTE" "$BRANCH" >/dev/null 2>&1; then
  echo "ERROR: Unable to fetch '$BRANCH' from remote '$REMOTE' (network/auth/url?)"
  # Do not assume this is first-push; without fetch, we cannot verify remote state.
  exit 1
fi

upstream_ref="refs/remotes/$REMOTE/$BRANCH"
upstream="$REMOTE/$BRANCH"

# If the remote-tracking branch doesn't exist after fetch, it's a confirmed first-push.
if ! git rev-parse --verify "$upstream_ref" >/dev/null 2>&1; then
  echo "Remote branch '$BRANCH' does not exist on '$REMOTE' (first push scenario)."
  # Safe to let gitwatch push to create it.
  exit 0
fi

# If local has no commits (fresh local repo), align refs and index to remote
# without modifying existing working files. This sets history/HEAD safely.
if ! git rev-parse --verify HEAD >/dev/null 2>&1; then
  echo "Local repository has no commits; aligning to $upstream without overwriting files..."

  # 1) Point the local branch ref to the remote tip (metadata-only).
  git update-ref "refs/heads/$BRANCH" "$upstream_ref"

  # 2) Make HEAD point to that branch (no checkout side effects).
  git symbolic-ref HEAD "refs/heads/$BRANCH"

  # 3) Rebuild the index from the remote tree (index-only; do not write work tree).
  git read-tree -m "$upstream"

  # 4) Set tracking for the local branch (records origin/main as upstream; affects config only, not index/work tree).
  git branch --set-upstream-to="$upstream" "$BRANCH"

  echo "Aligned HEAD and index to $upstream without modifying files."

  if git status --porcelain | grep -q .; then
    # Done aligning; but pre-flight needs to commit a baseline before gitwatch can safely commit/push additive changes.
    echo "NOTE: Changes detected, will need to commit a baseline."
  else
    # Done aligning; from here, gitwatch can safely commit/push additive changes.
    exit 0
  fi
fi

# If both local and remote have commits, ensure local contains remote.
if git rev-parse --verify HEAD >/dev/null 2>&1; then
  # If remote is not an ancestor of local, local is behind -> do nothing (not safe).
  if ! git merge-base --is-ancestor "$upstream" HEAD 2>/dev/null; then
    echo "WARNING: Local branch is behind '$upstream' (remote has commits not in local)."
    echo "Per policy, doing nothing: resolve manually (pull/rebase/merge) and retry."
    exit 1
  fi
fi

# If working tree differs from the remote-tracked content, push a baseline commit.
if git status --porcelain | grep -q .; then
  echo "Differences between working tree and remote-tracked content detected; creating baseline commit."

  # Stage everything (tracked + untracked; deletions, renames, and new files).
  git add -A

  # Create a time-stamped baseline commit
  git commit -m "$(date '+%Y-%m-%d %H:%M:%S') | auto-commit baseline in pre-flight"

  # Push non-interactively; fast-forward-only is enforced by config (push.ff=only).
  git push "$REMOTE" "$BRANCH" || {
    echo "ERROR: push failed; baseline commit created locally but not pushed."
    exit 1
  }

  echo "Baseline commit pushed to $upstream; starting Gitwatch on a clean slate."
  exit 0
fi

# Local is at/after remote (fast-forward push guaranteed). Safe to proceed.
echo "Sync check passed: local contains '$upstream'. Ready to push."
exit 0
