#!/usr/bin/env bash
set -euo pipefail

: "${REPO_DIR:=/mnt/docker}"
: "${GIT_DIR:=/mnt/.git}"
: "${BRANCH:=main}"
: "${REMOTE_REPO:=git@github.com:....git}"
: "${SSH_KEY:=/run/secrets/id_ed25519_github}"

echo

# Export once; no .git file in $REPO_DIR and no repeated flags needed
export GIT_DIR="$GIT_DIR"        # path to repo storage (named volume) [no writes to REPO_DIR] 
export GIT_WORK_TREE="$REPO_DIR" # working tree path (bind mount) with zero metadata writes

# Optional: ensure we run from anywhere and Git doesn't do discovery
cd /

# Check GitHub SSH auth
set +e
ssh -T git@github.com -i "$SSH_KEY" -o StrictHostKeyChecking=no -o BatchMode=yes
status=$?
set -e

echo

if [ "$status" -eq 1 ]; then
  echo "Successfully authenticated to GitHub via SSH."
elif [ "$status" -eq 255 ]; then
  echo "SSH authentication to GitHub failed."
  exit 1
else
  echo "Unexpected SSH status: $status"
  exit 2
fi

echo

# Prepare repo dir (lives entirely in named volume)
mkdir -p "$GIT_DIR"

# Initialize repository if needed
if [ ! -d "$GIT_DIR/objects" ]; then
  git config init.defaultBranch "$BRANCH"
  git init
  
  git config user.name "gitwatch"
  git config user.email "gitwatch@dsm.local"
  git config core.sshCommand "ssh -i $SSH_KEY -F /dev/null"
  git config commit.gpgsign false
  git config pull.rebase true

  # Set or update remote
  if git remote get-url origin >/dev/null 2>&1; then
    git remote set-url origin "$REMOTE_REPO"
  else
    git remote add origin "$REMOTE_REPO"
  fi

  # Ensure target branch exists locally
  if git rev-parse --verify "$BRANCH" >/dev/null 2>&1; then
    git checkout "$BRANCH"
  else
    git checkout -b "$BRANCH"
  fi

  # Initial commit if there are local changes in work tree
  if [ -n "$(git status --porcelain)" ]; then
    git add -A
    git commit -m "Init repository state"
  fi

  # If remote branch exists, rebase local on top, favoring remote on conflicts
  if git ls-remote --exit-code --heads origin "$BRANCH" >/dev/null 2>&1; then
    git pull --rebase -X theirs origin "$BRANCH"
  fi

  # Push and set upstream
  git push --set-upstream origin "$BRANCH"
else
  # Repo exists; ensure config is in place
  git config pull.rebase true
  git config core.sshCommand "ssh -i $SSH_KEY -F /dev/null"

  # Make sure remote is set correctly
  if git remote get-url origin >/dev/null 2>&1; then
    git remote set-url origin "$REMOTE_REPO"
  else
    git remote add origin "$REMOTE_REPO"
  fi

  # Ensure branch exists and is checked out
  if git rev-parse --verify "$BRANCH" >/dev/null 2>&1; then
    git checkout "$BRANCH"
  else
    git checkout -b "$BRANCH"
  fi
fi
