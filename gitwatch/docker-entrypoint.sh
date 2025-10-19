#!/usr/bin/env bash
set -euo pipefail

# Init repo if needed
if [ ! -d .git ]; then
  : "${REPO_DIR:=/mnt/repo}"
  : "${REMOTE_REPO:=git@github.com:mdjdev/dsm-container-manager.git}"
  : "${SSH_KEY:=/run/secrets/id_ed25519_github}"

  BRANCH="main"

  cd "$REPO_DIR"

  git init

  # Configuration
  git config init.defaultBranch main
  git config user.name "gitwatch"
  git config user.email "gitwatch@dsm.local"
  git config core.sshCommand "ssh -i $SSH_KEY -F /dev/null"
  git config commit.gpgsign false

  # Ensure/normalize remote
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

  # Commit all local changes if present (initial or subsequent)
  if [ -n "$(git status --porcelain)" ]; then
    git add -A
    git commit -m "Init repository state"
  fi

  # Detect if remote branch exists (remote may be empty)
  if git ls-remote --exit-code --heads origin "$BRANCH" >/dev/null 2>&1; then
    # Remote has the branch: rebase local commits on top, preferring local in conflicts
    git pull --rebase -X theirs origin "$BRANCH"
  fi

  # One push to set upstream (creates remote branch if needed)
  git push --set-upstream origin "$BRANCH"
fi

exec /usr/local/bin/gitwatch -r origin -b main /mnt/repo