#!/usr/bin/env bash
set -euo pipefail

: "${REPO_DIR:=/mnt/docker}"
: "${GIT_DIR:=/mnt/.git}"
: "${BRANCH:=main}"
: "${REMOTE:=origin}"
: "${REMOTE_URL:=git@github.com:mdjdev/redesigned-octo-fishstick.git}"
: "${SSH_KEY:=/run/secrets/id_ed25519_github}"
: "${COMMIT_MESSAGE:=Apply local changes after remote sync}"

export GIT_DIR="$GIT_DIR"
export GIT_WORK_TREE="$REPO_DIR"

# Init once
if [ ! -d "$GIT_DIR/objects" ]; then
  git init -b "$BRANCH"
fi

# Basic config
git config user.name "gitwatch"
git config user.email "gitwatch@dsm.local"
git config core.sshCommand "ssh -i $SSH_KEY -F /dev/null"
git config commit.gpgsign false
git config pull.ff only  # enforce fast-forward-only pulls [web:32][web:29]

# Ensure/normalize remote
if git remote get-url "$REMOTE" >/dev/null 2>&1; then
  git remote set-url "$REMOTE" "$REMOTE_URL"
else
  git remote add "$REMOTE" "$REMOTE_URL"
fi

# Ensure branch
if git rev-parse --verify "$BRANCH" >/dev/null 2>&1; then
  git checkout -f "$BRANCH"
else
  git checkout -b "$BRANCH"
fi

# 1) Fetch remote refs (no working-tree changes)
git fetch --prune "$REMOTE" "$BRANCH"  # safe; updates refs only [web:29]

# 2) Fast-forward only to remote if possible; aborts on divergence and leaves local untouched
if git rev-parse --verify "refs/remotes/$REMOTE/$BRANCH" >/dev/null 2>&1; then
  git merge --ff-only "$REMOTE/$BRANCH"  # fails if not fast-forwardable [web:25][web:32]
fi

# 3) Commit local changes (if any)
if [ -n "$(git status --porcelain)" ]; then
  git add -A
  git commit -m "$COMMIT_MESSAGE"
fi

# 4) Push (fast-forward only by default); creates upstream if missing
git push --set-upstream "$REMOTE" "$BRANCH"  # rejected if remote is ahead/diverged [web:27][web:29]
