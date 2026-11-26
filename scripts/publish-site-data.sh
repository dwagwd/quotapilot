#!/bin/bash
# Publish only site/data/ from HEAD to origin/main, without pushing any other local commit.
# Usage: scripts/publish-site-data.sh [--dry-run] [commit message]
set -euo pipefail

DRY_RUN=0
MESSAGE=""
for arg in "$@"; do
  case "$arg" in
    --dry-run) DRY_RUN=1 ;;
    *) MESSAGE="$arg" ;;
  esac
done
[ -n "$MESSAGE" ] || MESSAGE="Site data: daily check $(date +%F)"

TOPLEVEL="$(git rev-parse --show-toplevel)"
if [ "$(pwd -P)" != "$(cd "$TOPLEVEL" && pwd -P)" ]; then
  echo "Run this from the repository root: $TOPLEVEL" >&2
  exit 1
fi
GIT_DIR_PATH="$(git rev-parse --git-dir)"
for marker in MERGE_HEAD CHERRY_PICK_HEAD REVERT_HEAD rebase-merge rebase-apply; do
  if [ -e "$GIT_DIR_PATH/$marker" ]; then
    echo "A merge, rebase, cherry-pick or revert is in progress ($marker); finish it first." >&2
    exit 1
  fi
done

git fetch --quiet origin main

WORK="$(mktemp -d "${TMPDIR:-/tmp}/publish-site-data.XXXXXX")"
trap 'rm -rf "$WORK"' EXIT
export GIT_INDEX_FILE="$WORK/index"

git read-tree origin/main
git rm -r --cached -q -f --ignore-unmatch site/data
git read-tree --prefix=site/data/ "HEAD:site/data"
TREE="$(git write-tree)"
unset GIT_INDEX_FILE

if [ "$TREE" = "$(git rev-parse 'origin/main^{tree}')" ]; then
  echo "site data already live"
  exit 0
fi

CHANGED="$(git diff --name-only origin/main "$TREE")"
if [ -z "$CHANGED" ]; then
  echo "site data already live"
  exit 0
fi
if printf '%s\n' "$CHANGED" | grep -qv '^site/data/'; then
  echo "Refusing to publish: paths outside site/data/ would change:" >&2
  printf '%s\n' "$CHANGED" | grep -v '^site/data/' >&2
  exit 1
fi

# Validation reads the working tree, so only run it when that matches HEAD.
if [ -f site/scripts/validate-data.mjs ] && command -v node >/dev/null 2>&1; then
  if git diff --quiet HEAD -- site/data; then
    node site/scripts/validate-data.mjs
  else
    echo "site/data has uncommitted changes; skipping validation."
  fi
fi

echo "Changes to publish:"
git diff --stat origin/main "$TREE"

if [ "$DRY_RUN" = 1 ]; then
  echo "Dry run: nothing committed or pushed."
  exit 0
fi

COMMIT="$(git commit-tree "$TREE" -p origin/main -m "$MESSAGE")"
git push origin "$COMMIT:refs/heads/main"
echo "Pushed $COMMIT"
