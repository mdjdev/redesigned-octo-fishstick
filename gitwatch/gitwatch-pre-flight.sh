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

echo "Start pre-flight."

################################################################################
# Configuration
################################################################################

: "${REPO_DIR:=/mnt/repo}"
: "${GIT_DIR:=/mnt/.git}"
: "${REMOTE:=origin}"
: "${BRANCH:=main}"
: "${REMOTE_URL:=git@github.com:mdjdev/redesigned-octo-fishstick.git}"
: "${SSH_KEY:=/run/secrets/id_ed25519_github}"

 echo "DEBUG: REPO_DIR=${REPO_DIR}"
 echo "DEBUG: GIT_DIR=${GIT_DIR}"
 echo "DEBUG: REMOTE=${REMOTE}"
 echo "DEBUG: BRANCH=${BRANCH}"
 echo "DEBUG: REMOTE_URL=${REMOTE_URL}"
 echo "DEBUG: SSH_KEY=${SSH_KEY}"

# Export Git environment variables to use separated directory layout
export GIT_DIR="$GIT_DIR"
export GIT_WORK_TREE="$REPO_DIR"

################################################################################
# SSH Validation
################################################################################

# Verify SSH key exists.
if [ ! -f "$SSH_KEY" ]; then
  echo "Error: SSH key not found at $SSH_KEY."
  exit 1
fi

# Ensure SSH key has restrictive permissions.
if [ "$(stat -c %a -- "$SSH_KEY")" != 600 ]; then 
  echo "Error: SSH key at $SSH_KEY has mismatching permissions or ownership."
  echo "Hint: ensure the key is owned by the running user and has mode 600, or supply a valid secret."
  exit 1
fi

echo "SSH key ${SSH_KEY} is available and has restrictive permissions."

# Probe GitHub SSH auth (non-interactive).
set +e
ssh -T git@github.com \
    -i "$SSH_KEY" \
    -o BatchMode=yes \
    -o StrictHostKeyChecking=accept-new \
    -F /dev/null \
    2>/dev/null
status=$?
set -e

if [ "$status" -eq 1 ]; then
  echo "Successfully authenticated to GitHub via SSH."
elif [ "$status" -eq 255 ]; then
  echo "SSH authentication to GitHub failed."
  exit 1
else
  echo "Unexpected SSH status: $status"
  exit 2
fi

################################################################################
# Repository Initialization
################################################################################

# Initialize empty repository if not already initialized.
if [ ! -d "$GIT_DIR/objects" ]; then
  git init -b "$BRANCH"
fi

################################################################################
# Git Configuration
################################################################################

# Set identity for commits.
git config user.name "gitwatch"
git config user.email "gitwatch@dsm.local"

# Configure SSH command to use specific key.
git config core.sshCommand "ssh -i $SSH_KEY -o StrictHostKeyChecking=accept-new -F /dev/null"

# Disable GPG signing (non-interactive environment).
git config commit.gpgsign false

# Safety: only allow fast-forward pushes.
git config push.ff only

# Automatically prune deleted remote branches.
git config fetch.prune true

################################################################################
# Basic Remote Setup
################################################################################

# Ensure remote exists/URL is correct.
if git remote get-url "$REMOTE" >/dev/null 2>&1; then
  git remote set-url "$REMOTE" "$REMOTE_URL"
else
  git remote add "$REMOTE" "$REMOTE_URL"
fi

# Always fetch first; if this fails, we cannot reason about safety.
if ! git fetch "$REMOTE" "$BRANCH" >/dev/null 2>&1; then
  echo "ERROR: Unable to fetch '$BRANCH' from remote '$REMOTE' (network/auth/url?)"
  # Do not assume this is first-push; without fetch, we cannot verify remote state.
  exit 1
fi

upstream_ref="refs/remotes/$REMOTE/$BRANCH"
upstream="$REMOTE/$BRANCH"

################################################################################
# Empty Remote Handling
################################################################################

# If the remote-tracking branch is missing (first push).
if ! git rev-parse --verify "$upstream_ref" >/dev/null 2>&1; then
  echo "Remote branch '$BRANCH' does not exist on '$REMOTE' (first push scenario)."

  # Ensure HEAD targets the local branch without checkout.
  if ! git rev-parse --verify "refs/heads/$BRANCH" >/dev/null 2>&1; then
    # Attach future commits to branch.
    git symbolic-ref HEAD "refs/heads/$BRANCH"
  fi

  # If working tree is clean, create an empty initial commit to establish the branch.
  if ! git status --porcelain | grep -q .; then
    git commit --allow-empty -m "pre-flight: empty baseline ($(date '+%Y-%m-%d %H:%M:%S'))"
  else
    # Otherwise, commit actual content as baseline.
    git add -A
    git commit -m "pre-flight: initial baseline ($(date '+%Y-%m-%d %H:%M:%S'))"
  fi

  # Push and set upstream for future fast-forward-only pushes.
  git push -u "$REMOTE" "$BRANCH" || {
    echo "ERROR: initial push failed; baseline created locally but not pushed."
    exit 1
  }

  echo "Initial baseline commit pushed to '$upstream'; Gitwatch will start on a clean slate."
  echo "Pre-flight finished: local is aligned with '$upstream'; ready to start Gitwatch."
  exit 0
fi

################################################################################
# Local Upstream Alignment
################################################################################

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
    echo "Pre-flight finished: local is aligned with '$upstream'; ready to start Gitwatch."
    exit 0
  fi
fi

# If both remote and local have commits, ensure local contains remote.
if git rev-parse --verify "$upstream_ref" >/dev/null 2>&1 && \
   git rev-parse --verify HEAD >/dev/null 2>&1; then
  # If remote is not an ancestor of local, local is behind -> do nothing (not safe).
  if ! git merge-base --is-ancestor "$upstream" HEAD 2>/dev/null; then
    echo "WARNING: Local branch is behind '$upstream' (remote has commits not in local)."
    echo "Per policy, doing nothing: resolve manually (pull/rebase/merge) and retry."
    exit 1
  fi
fi

################################################################################
# Baseline Update
################################################################################

# If working tree differs from the remote-tracked content, push a baseline commit.
if git status --porcelain | grep -q .; then
  echo "Differences between working tree and remote-tracked content detected; creating baseline commit."

  # Stage everything (tracked + untracked; deletions, renames, and new files).
  git add -A

  # Create a time-stamped baseline commit
  git commit -m "pre-flight: baseline change ($(date '+%Y-%m-%d %H:%M:%S'))"

  # Push non-interactively; fast-forward-only is enforced by config (push.ff=only).
  git push "$REMOTE" "$BRANCH" || {
    echo "ERROR: push failed; baseline commit created locally but not pushed."
    exit 1
  }

  echo "Baseline commit pushed to '$upstream'; Gitwatch will start on a clean slate."
fi

################################################################################
# Finish
################################################################################

# Local is at/after remote (fast-forward push guaranteed). Safe to proceed.
echo "Pre-flight finished: local is aligned with '$upstream'; ready to start Gitwatch."
exit 0
