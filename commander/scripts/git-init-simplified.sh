#!/usr/bin/env bash
set -euo pipefail

# Configuration
: "${REPO_DIR:=/mnt/docker}"  # working tree (bind mount; no .git here)
: "${GIT_DIR:=/mnt/.git}"     # repository storage (named volume)
: "${BRANCH:=main}"
: "${REMOTE:=origin}"
: "${REMOTE_URL:=git@github.com:mdjdev/redesigned-octo-fishstick.git}"
: "${SSH_KEY:=/run/secrets/id_ed25519_github}"
: "${COMMIT_MESSAGE:=Apply local changes after remote sync}"

# Operate with explicit repo/work tree without writing .git to REPO_DIR
export GIT_DIR="$GIT_DIR"
export GIT_WORK_TREE="$REPO_DIR"

# Optional: ensure we run from anywhere and Git doesn't do discovery
cd /

echo

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

if [ ! -d "$GIT_DIR" ]; then
  echo "$GIT_DIR must be created in Dockerfile with correct permissions"
  exit 3
fi

if [ ! -d "$GIT_DIR/objects" ]; then
  git init -b "$BRANCH"
fi

git config user.name "gitwatch"
git config user.email "gitwatch@dsm.local"
git config core.sshCommand "ssh -i $SSH_KEY -F /dev/null"
git config commit.gpgsign false
git config pull.rebase true

# Ensure/normalize remote
if git remote get-url "$REMOTE" >/dev/null 2>&1; then
  git remote set-url "$REMOTE" "$REMOTE_URL"
else
  git remote add "$REMOTE" "$REMOTE_URL"
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