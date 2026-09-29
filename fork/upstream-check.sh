#!/usr/bin/env bash
# Runs the static guard, pushes the branch to the fork and waits for upstream-gate.yml on it:
# the build, harnesses and lint upstream expects but has no CI for.
#
# Usage: fork/upstream-check.sh [branch]
set -euo pipefail

BRANCH="${1:-$(git branch --show-current)}"
FORK=ajchemist/tinycast
HERE="$(cd "$(dirname "$0")" && pwd)"

"$HERE/upstream-guard.sh" "$BRANCH"
git push -q --force-with-lease fork "$BRANCH:refs/heads/$BRANCH"
SHA="$(git rev-parse "$BRANCH")"
gh workflow run upstream-gate.yml -R "$FORK" --ref personal -f ref="$BRANCH" -f sha="$SHA"
run=""
while [ -z "$run" ]; do
  sleep 3
  run="$(gh run list -R "$FORK" -w upstream-gate.yml -L 10 --json databaseId,displayTitle \
    -q "[.[] | select(.displayTitle | endswith(\"@ $SHA\"))][0].databaseId // empty")"
done
gh run watch "$run" -R "$FORK" --exit-status
