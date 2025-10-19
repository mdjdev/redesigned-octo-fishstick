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

# Ensure remote exists
if ! git remote get-url "$REMOTE" >/dev/null 2>&1; then
  git remote add "$REMOTE" "$REMOTE_URL"
fi

# Detect local dirty state
has_local=0
if [ -n "$(git status --porcelain)" ]; then
  has_local=1
fi

# Fetch remote and detect whether target branch exists there
git fetch "$REMOTE" --prune || true
remote_branch_exists=0
if git show-ref --verify --quiet "refs/remotes/$REMOTE/$BRANCH"; then
  remote_branch_exists=1
fi

# If there are no local edits
if [ "$has_local" -eq 0 ]; then
  if [ "$remote_branch_exists" -eq 1 ]; then
    git checkout -B "$BRANCH" || true
    git reset --hard "$REMOTE/$BRANCH"
    echo "No local edits; synced to $REMOTE/$BRANCH."
  else
    # No local edits and no remote branch: ensure branch exists locally, but do not push automatically
    git checkout -B "$BRANCH" || true
    echo "No local edits; remote branch '$REMOTE/$BRANCH' does not exist yet. Local branch prepared."
  fi
  exit 0
fi

# Create a temporary patch of local changes without touching working tree
patch_file="$(mktemp)"
git diff -p > "$patch_file" || true

# Temporary work area for dry-run apply
tmpdir="$(mktemp -d)"
cleanup() { rm -f "$patch_file"; rm -rf "$tmpdir"; }
trap cleanup EXIT

# Prepare clean baseline in tmpdir:
# - If remote branch exists: checkout that as baseline.
# - Else: use an empty tree as baseline (initial branch creation scenario).
if [ "$remote_branch_exists" -eq 1 ]; then
  git --work-tree="$tmpdir" checkout -f "$REMOTE/$BRANCH" >/dev/null 2>&1 || true
else
  # Build an empty baseline in tmpdir by clearing it and not checking out anything.
  # Create empty directory; no files present means patch applies against an empty tree.
  # Ensure the index file path is isolated for the check step below.
  :
fi

# Try a dry-run apply to detect conflicts using an isolated index
set +e
GIT_INDEX_FILE="$tmpdir/.git-index" git --work-tree="$tmpdir" apply --check "$patch_file"
dry_status=$?
set -e

if [ $dry_status -ne 0 ]; then
  if [ "$remote_branch_exists" -eq 1 ]; then
    echo "Conflicts detected between local edits and remote '$REMOTE/$BRANCH' – leaving files unchanged." >&2
  else
    echo "Conflicts detected applying local edits onto an empty new branch '$BRANCH' – leaving files unchanged." >&2
  fi
  echo "Useful diagnostics:" >&2
  echo "  • Local status:" >&2
  git status --porcelain || true
  echo "  • Incoming changes (since your base):" >&2
  if [ "$remote_branch_exists" -eq 1 ]; then
    git log --oneline --decorate --graph --boundary HEAD.."$REMOTE/$BRANCH" || true
    echo "  • Local vs remote diff (names):" >&2
    git diff --name-status "$REMOTE/$BRANCH" || true
  else
    echo "  • Remote branch does not exist; baseline is empty tree." >&2
    echo "  • Local paths changed (names):" >&2
    git diff --name-only || true
  fi
  echo "  • Detailed local patch saved to: $patch_file" >&2
  echo "    You can inspect or manually apply with: git apply --3way \"$patch_file\"" >&2

  if [ "${DEBUG_CONFLICTS:-1}" = "1" ]; then
    echo "Generating conflict-marked artifact in a temporary worktree..."
    tmpcw="$(mktemp -d)"
    report="$(mktemp)"
    tarfile="${CONFLICT_ARCHIVE:-conflict-artifact.tgz}"

    if [ "$remote_branch_exists" -eq 1 ]; then
      GIT_WORK_TREE="$tmpcw" git checkout -f "$REMOTE/$BRANCH" >/dev/null 2>&1 || true
    else
      # Empty baseline for new branch case
      : # leave tmpcw empty
    fi

    set +e
    GIT_WORK_TREE="$tmpcw" git apply --3way "$patch_file"
    apply3_status=$?
    set -e

    {
      echo "Remote: $REMOTE/$BRANCH (exists: $remote_branch_exists)"
      echo "Timestamp: $(date -u +%Y-%m-%dT%H:%M:%SZ)"
      echo
      echo "Incoming commits relative to your local base:"
      if [ "$remote_branch_exists" -eq 1 ]; then
        git log --oneline --decorate --graph --boundary HEAD.."$REMOTE/$BRANCH" || true
      else
        echo "(none; remote branch not found)"
      fi
      echo
      echo "Paths differing vs baseline:"
      if [ "$remote_branch_exists" -eq 1 ]; then
        git diff --name-status "$REMOTE/$BRANCH" || true
      else
        git diff --name-only || true
      fi
      echo
      echo "Local patch file: $patch_file"
      echo "3-way apply status: $apply3_status (0 means no conflicts; non-zero indicates conflicts with markers in files below)"
      echo
      echo "Conflicted files in artifact (if any):"
      (cd "$tmpcw" && git status --porcelain 2>/dev/null || true)
    } > "$report"

    tar -czf "$tarfile" -C "$tmpcw" . -C / "$report" "$patch_file"

    echo "Saved conflict artifact: $tarfile"
    echo "Includes: conflict-marked files, diagnostics report, and your local patch."
  fi

  exit 1
fi

# Clean path
if [ "$remote_branch_exists" -eq 1 ]; then
  git checkout -B "$BRANCH" || true
  git reset --hard "$REMOTE/$BRANCH"
else
  # No remote branch yet: start a clean local branch without touching current working files
  git checkout -B "$BRANCH" || true
  git reset --hard # to current index; since we didn't modify index, it's a clean base for applying the patch
fi

# Apply local patch for real
git apply "$patch_file"

# Stage and commit if there are changes
if ! git diff --quiet; then
  git add -A
  if ! git diff --cached --quiet; then
    git commit -m "$COMMIT_MESSAGE"
  fi
fi

# If remote branch did not exist, create it now with the first push
if [ "$remote_branch_exists" -eq 0 ]; then
  git push --set-upstream "$REMOTE" "$BRANCH"
  echo "Created remote branch '$REMOTE/$BRANCH' and pushed first commit."
else
  echo "Applied local edits cleanly and committed on top of $REMOTE/$BRANCH."
fi
