#!/usr/bin/env bash

################################################################################
# Git Sync Script for Separated Repository Layout
################################################################################
# Description:
#   Synchronizes a working tree with a remote Git repository using a separated
#   .git directory layout. Designed for Docker containers with mounted volumes,
#   this script safely adopts remote changes while preserving local additions.
#
# Usage:
#   ./git-sync.sh
#
# Environment Variables:
#   REPO_DIR            Working tree location (default: /mnt/docker)
#   GIT_DIR             Git metadata location (default: /mnt/.git)
#   BRANCH              Branch name (default: main)
#   REMOTE              Remote name (default: origin)
#   REMOTE_URL          Remote repository URL (required)
#   SSH_KEY             Path to SSH private key (default: /run/secrets/id_ed25519_github)
#   COMMIT_MESSAGE      Message for local commits (default: Adopt local non-conflicting changes)
#
# Exit Codes:
#   0   Success - repository synchronized or published
#   1   Error - SSH key missing, permission issue, or race condition detected
#
# Author: mdjdev
################################################################################

set -euo pipefail

################################################################################
# Configuration and Environment Setup
################################################################################

# Set defaults for all required variables
: "${REPO_DIR:=/mnt/docker}"
: "${GIT_DIR:=/mnt/.git}"
: "${BRANCH:=main}"
: "${REMOTE:=origin}"
: "${REMOTE_URL:=git@github.com:mdjdev/redesigned-octo-fishstick.git}"
: "${SSH_KEY:=/run/secrets/id_ed25519_github}"
: "${COMMIT_MESSAGE:=Adopt local non-conflicting changes}"

# Export Git environment variables to use separated directory layout
export GIT_DIR GIT_WORK_TREE="$REPO_DIR"
cd /

################################################################################
# Pre-flight Validation
################################################################################

# Verify SSH key exists and has correct permissions
if [ ! -f "$SSH_KEY" ]; then
  echo "Error: SSH key not found at $SSH_KEY" >&2
  exit 1
fi

# Ensure SSH key has restrictive permissions (required by SSH)
if [ -w "$SSH_KEY" ]; then
  chmod 600 "$SSH_KEY" 2>/dev/null || {
    echo "Warning: Unable to set SSH key permissions to 600" >&2
  }
fi

################################################################################
# Repository Initialization
################################################################################

# Create Git directory structure if missing
[ -d "$GIT_DIR" ] || mkdir -p "$GIT_DIR"

# Initialize empty repository if not already initialized
if [ ! -d "$GIT_DIR/objects" ]; then
  git init -b "$BRANCH"
  echo "Initialized new Git repository"
fi

################################################################################
# Git Configuration
################################################################################

# Set identity for commits (non-interactive CI environment)
git config user.name "gitwatch"
git config user.email "gitwatch@dsm.local"

# Configure SSH command to use specific key without host verification
git config core.sshCommand "ssh -i $SSH_KEY -o StrictHostKeyChecking=accept-new -F /dev/null"

# Disable GPG signing (non-interactive environment)
git config commit.gpgsign false

# Safety: only allow fast-forward merges and pushes
git config pull.ff only
git config push.ff only

# Automatically prune deleted remote branches on fetch
git config fetch.prune true

################################################################################
# Remote Configuration
################################################################################

# Add or update remote URL
if git remote get-url "$REMOTE" >/dev/null 2>&1; then
  git remote set-url "$REMOTE" "$REMOTE_URL"
else
  git remote add "$REMOTE" "$REMOTE_URL"
fi

################################################################################
# Branch Setup
################################################################################

# Ensure local branch exists and is checked out
if git show-ref --verify --quiet "refs/heads/$BRANCH"; then
  # Branch exists, switch to it
  git checkout "$BRANCH" 2>/dev/null || git switch "$BRANCH" 2>/dev/null
else
  # Create new branch
  git checkout -b "$BRANCH" 2>/dev/null || git switch -c "$BRANCH" 2>/dev/null
fi

################################################################################
# Fetch Remote State
################################################################################

# Fetch remote branch (may not exist yet on first run)
if ! git fetch "$REMOTE" "$BRANCH" 2>&1; then
  echo "Warning: Unable to fetch from remote, proceeding with local state"
fi

# Define remote branch references
upstream_ref="refs/remotes/$REMOTE/$BRANCH"
upstream="$REMOTE/$BRANCH"

################################################################################
# Synchronization Logic
################################################################################

# Case A: Remote branch does not exist - publish local state
if ! git rev-parse --verify "$upstream_ref" >/dev/null 2>&1; then
  echo "Remote branch does not exist, creating from local state..."
  
  # If local repository has no commits, create initial commit
  if ! git rev-parse --verify "HEAD^{commit}" >/dev/null 2>&1; then
    git add -A
    git commit -m "Initial commit from restored working tree"
    echo "Created initial commit"
  fi
  
  # Push to create remote branch
  git push --set-upstream "$REMOTE" "$BRANCH"
  echo "Remote branch created and published"
  exit 0
fi

# Case B: Remote branch exists - synchronize with remote
echo "Remote branch exists, synchronizing..."

# Check if local state differs from remote
if ! git diff --quiet HEAD "$upstream" 2>/dev/null; then
  # Verify no conflicting changes exist
  base_commit=$(git merge-base HEAD "$upstream" 2>/dev/null || echo "")
  
  if [ -n "$base_commit" ]; then
    # Check for merge conflicts using merge-tree
    if git merge-tree "$base_commit" HEAD "$upstream" | grep -q "^changed in both"; then
      echo "Conflict detected: remote-tracked files differ locally"
      echo "Manual intervention required - leaving files untouched"
      exit 0
    fi
  fi

  # Fast-forward only pull per config; will fail if not FF
  # TODO: Geht ff pull wenn lokal Changes vorhanden sind?
  git pull || {
    echo "Pull was not a fast-forward; leaving repository untouched."
    exit 0
  }

  # Check for uncommitted local changes
  if [ -n "$(git status --porcelain)" ]; then
    echo "Local changes detected, committing..."
    
    # Stage all changes
    git add -A
    
    # Create commit with local additions
    git commit -m "$COMMIT_MESSAGE"
    
    # Push changes to remote
    git push --set-upstream "$REMOTE" "$BRANCH"
    echo "Changes pushed successfully"
  else
    echo "No local changes detected - repository is synchronized"
  fi
fi

echo "Synchronization complete"
exit 0
