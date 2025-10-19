#!/usr/bin/env bash
set -euo pipefail

# Config
: "${REPO_DIR:=/mnt/docker}"            # working tree (no .git here)
: "${GIT_DIR:=/mnt/.git}"               # repo storage (named volume)
: "${BRANCH:=main}"
: "${REMOTE:=origin}"
: "${REMOTE_URL:=git@github.com:mdjdev/redesigned-octo-fishstick.git}"
: "${SSH_KEY:=/run/secrets/id_ed25519_github}"
: "${COMMIT_MESSAGE:=Apply local changes after remote sync}"

# Operate with explicit repo/work tree
export GIT_DIR="$GIT_DIR"
export GIT_WORK_TREE="$REPO_DIR"

cd /

# Ensure repo exists
[ -d "$GIT_DIR" ] || { echo "$GIT_DIR must exist"; exit 3; }
[ -d "$GIT_DIR/objects" ] || git init -b "$BRANCH"

# Baseline config
git config user.name "gitwatch"
git config user.email "gitwatch@dsm.local"
git config core.sshCommand "ssh -i $SSH_KEY -F /dev/null"
git config commit.gpgsign false
git config pull.ff only     # refuse non-FF pulls (safer default)
git config push.ff only     # refuse non-FF pushes

# Remote setup
if git remote get-url "$REMOTE" >/dev/null 2>&1; then
  git remote set-url "$REMOTE" "$REMOTE_URL"
else
  git remote add "$REMOTE" "$REMOTE_URL"
fi

# Ensure branch exists and is active
if git rev-parse --verify "$BRANCH" >/dev/null 2>&1; then
  git checkout -f "$BRANCH"
else
  git checkout -b "$BRANCH"
fi

# Fetch remote refs only (no working tree changes)
git fetch --prune "$REMOTE" "$BRANCH"  # safe metadata update

# Attempt fast-forward update only; exit if not fast-forwardable
if git rev-parse --verify "refs/remotes/$REMOTE/$BRANCH" >/dev/null 2>&1; then
  if ! git merge --ff-only "$REMOTE/$BRANCH"; then  # fails on divergence, leaves files unchanged
    echo "Remote diverged; leaving local as-is."
    exit 0
  fi
fi

# Commit local changes (if any)
if [ -n "$(git status --porcelain)" ]; then
  git add -A
  git commit -m "$COMMIT_MESSAGE"
fi

# Push fast-forward only; creates remote branch if missing, otherwise fails if not FF
git push --set-upstream "$REMOTE" "$BRANCH"  # governed by push.ff=only
