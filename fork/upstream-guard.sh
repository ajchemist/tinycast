#!/usr/bin/env bash
# Checks a branch meant for abue-ammar/tinycast against the rules its maintainer enforces.
# Static only: history, scope and hygiene. The build, harnesses and lint run in upstream-gate.yml.
#
# Usage: fork/upstream-guard.sh [branch] [base]
#   branch  defaults to HEAD
#   base    defaults to upstream main (the `origin` remote of this checkout, else a fresh fetch)
set -uo pipefail

BRANCH="${1:-HEAD}"
BASE="${2:-}"
UPSTREAM_URL="https://github.com/abue-ammar/tinycast.git"

if [ -z "$BASE" ]; then
  git fetch -q "$UPSTREAM_URL" main || { echo "cannot fetch upstream main" >&2; exit 2; }
  BASE=FETCH_HEAD
fi

failures=0
warnings=0
fail() { echo "✗ $*"; failures=$((failures + 1)); }
warn() { echo "! $*"; warnings=$((warnings + 1)); }
ok() { echo "✓ $*"; }

RANGE="$BASE..$BRANCH"
COMMITS="$(git rev-list "$RANGE")"
[ -n "$COMMITS" ] || { echo "no commits in $RANGE"; exit 2; }
FILES="$(git diff --name-only "$BASE...$BRANCH")"

# CONTRIBUTING: rebased on main, squashed into logical commits.
if git merge-base --is-ancestor "$BASE" "$BRANCH"; then
  ok "based on the current upstream main"
else
  fail "not rebased on upstream main — git rebase upstream main"
fi
if [ -n "$(git rev-list --merges "$RANGE")" ]; then
  fail "merge commits on the branch — rebase instead"
else
  ok "linear history ($(echo "$COMMITS" | wc -l | tr -d ' ') commit(s))"
fi

# coauthors.yml blocks the merge; the host rules forbid the trailer outright.
ai='claude|anthropic|codex|openai|chatgpt|copilot|cursor|gemini|devin|aider|windsurf|codeium'
if git log --format=%B "$RANGE" | grep -iE "^co-authored-by:.*($ai)|generated with" >/dev/null; then
  fail "a commit credits an AI tool (Co-authored-by / Generated with)"
else
  ok "no AI attribution"
fi

# Imperative subjects: "Add …", never "Added …" / "Adding …".
while read -r sha subject; do
  first="${subject%% *}"
  case "$first" in
    *ed | *ing) warn "$sha subject may not be imperative: $subject" ;;
  esac
  case "$subject" in *.) warn "$sha subject ends with a period: $subject" ;; esac
  [ "${#subject}" -le 72 ] || warn "$sha subject is ${#subject} characters"
done < <(git log --format='%h %s' "$RANGE")

# Maintainer on #887 and #1181: an extension fix may not touch the palette or any core file.
if echo "$FILES" | grep -qE '^(Tinycast/Features/Extensions/|Scripts/raycast-runtime/)'; then
  outside="$(echo "$FILES" | grep '^Tinycast/' \
    | grep -vE '^Tinycast/(Features/Extensions/|Resources/RaycastRuntime\.generated\.js$)' || true)"
  if [ -n "$outside" ]; then
    fail "an extension change reaches outside Features/Extensions (see #887, #1181):"
    echo "$outside" | sed 's/^/    /'
  else
    ok "extension change stays inside Features/Extensions"
  fi
fi
if echo "$FILES" | grep -qE '^Tinycast/DesignSystem/Scrolling/(EdgeDissolve|ThinScrollbar)\.swift$'; then
  fail "EdgeDissolve.swift / ThinScrollbar.swift are off-limits (AGENTS.md)"
fi

# Nothing that only exists on the fork's `personal` branch.
leaked="$(echo "$FILES" | grep -E '^(fork/|\.github/workflows/(personal-release|upstream-gate)\.yml$)' || true)"
if [ -n "$leaked" ]; then
  fail "fork-only files on the branch:"
  echo "$leaked" | sed 's/^/    /'
else
  ok "no fork-only files"
fi

# Model purity is enforced by compilation too, but this fails faster.
impure="$(git grep -ln 'import AppKit\|import SwiftUI\|import Cocoa' "$BRANCH" -- 'Tinycast/Features/*/Model/' || true)"
[ -z "$impure" ] && ok "Model/ stays free of AppKit and SwiftUI" || { fail "UI import in Model/:"; echo "$impure"; }

# Generated files are never hand-edited, and their source moves with them.
if echo "$FILES" | grep -q '^Scripts/raycast-runtime/src/' \
  && ! echo "$FILES" | grep -q '^Tinycast/Resources/RaycastRuntime\.generated\.js$'; then
  fail "runtime source changed but RaycastRuntime.generated.js was not rebuilt"
fi
if echo "$FILES" | grep -q '^project\.yml$' && ! echo "$FILES" | grep -q '^Tinycast\.xcodeproj/'; then
  fail "project.yml changed without a regenerated Tinycast.xcodeproj"
fi

# "Anything in docs/ your change makes wrong is fixed" — a nudge, not proof.
for feature in $(echo "$FILES" | sed -n 's|^Tinycast/Features/\([^/]*\)/.*|\1|p' | sort -u); do
  echo "$FILES" | grep -q '^docs/' || warn "Features/$feature changed with no docs/ change — confirm none is wrong"
done

echo
echo "$failures failure(s), $warnings warning(s)"
[ "$failures" -eq 0 ]
