#!/usr/bin/env bash
# =============================================================================
# .gitea/scripts/finish-issue.sh  —  lives IN the repository.
#
# This copy is shipped with the Coder Agent action: if the file is missing from
# the base branch, the action commits it there before the agent starts. Once it
# is in the repo you own it — edit it freely, the action will not touch it again.
#
# The agent only edits files; this wrapper does all git deterministically, so a
# model that forgets `git add` or stops mid-thought can't break the pipeline.
#
# Invoke it WITH bash (no executable bit needed, so no file-mode noise in the
# diff — this matters: a chmod would show up as 100644 -> 100755 in the commit):
#
#   bash .gitea/scripts/finish-issue.sh <branch> <commit message>
#
# Run it from anywhere inside the working tree; it locates the repo root itself.
# =============================================================================
set -euo pipefail

BRANCH="${1:?usage: bash .gitea/scripts/finish-issue.sh <branch> <commit-msg>}"
MSG="${2:?usage: bash .gitea/scripts/finish-issue.sh <branch> <commit-msg>}"

# The script lives in the repo, so git itself tells us the root.
REPO_DIR=$(git rev-parse --show-toplevel 2>/dev/null) || {
  echo "finish-issue: not inside a git repository"; exit 1; }
cd "$REPO_DIR"
echo "finish-issue: repo=$REPO_DIR branch=$BRANCH"

# Identity: the template sets GIT_AUTHOR_*/GIT_COMMITTER_* as env vars, but
# git config may be empty in non-login shells. Set it only if missing.
git config user.name  >/dev/null 2>&1 || \
  git config user.name  "${GIT_AUTHOR_NAME:-coder-agent}"
git config user.email >/dev/null 2>&1 || \
  git config user.email "${GIT_AUTHOR_EMAIL:-coder-agent@localhost}"

# Don't let an accidental file-mode change sneak into the commit.
git config core.fileMode false

git checkout -B "$BRANCH"
git add -A

if git diff --cached --quiet; then
  echo "finish-issue: nothing to commit — the agent made no file changes."
  exit 2
fi

git commit -m "$MSG"

# Fetch the remote branch first so --force-with-lease has a ref to compare
# against: a re-run of the same issue rebuilds the branch from the base, which
# is a legitimate divergence, but only ever on this agent-owned branch.
git fetch origin "$BRANCH" >/dev/null 2>&1 || true
git push -u origin "$BRANCH" \
  || git push -u --force-with-lease origin "$BRANCH" \
  || { echo "finish-issue: push rejected — resolve $BRANCH on the remote manually."; exit 3; }
echo "finish-issue: pushed $BRANCH"
