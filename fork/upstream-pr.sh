#!/usr/bin/env bash
# Opens a pull request on abue-ammar/tinycast only once every gate the maintainer runs would pass.
#
# Usage: fork/upstream-pr.sh <issue> <body.md> [branch]
#   issue    the issue the PR closes; it must carry the `approved` label
#   body.md  the filled-in PR template (.github/PULL_REQUEST_TEMPLATE.md)
#   branch   defaults to the current branch
set -euo pipefail

ISSUE="${1:?issue number}"
BODY="${2:?PR body file}"
BRANCH="${3:-$(git branch --show-current)}"
UPSTREAM=abue-ammar/tinycast
FORK=ajchemist/tinycast
HERE="$(cd "$(dirname "$0")" && pwd)"

die() { echo "✗ $*" >&2; exit 1; }

# A PR whose linked issue isn't `approved` is closed the moment it opens.
labels="$(gh issue view "$ISSUE" -R "$UPSTREAM" --json labels -q '[.labels[].name] | join(",")')"
[[ ",$labels," == *",approved,"* ]] || die "#$ISSUE is not labelled approved (labels: ${labels:-none})"
echo "✓ #$ISSUE is approved"

grep -qE "^Closes #$ISSUE\b" "$BODY" || die "the body must say 'Closes #$ISSUE' on its own line"
for section in "Related issue" "What changed" "Memory footprint" "Tests & validation"; do
  grep -q "^## $section" "$BODY" || die "the body is missing the '## $section' section"
done
grep -qE '^\| (Idle after launch|Palette closed, settled) +\| +\|' "$BODY" \
  && die "the memory table still has empty cells"
grep -q '<!--' "$BODY" && echo "! the body still has template comments — delete or answer them"
echo "✓ body follows the template"

"$HERE/upstream-guard.sh" "$BRANCH"

sha="$(git rev-parse "$BRANCH")"
[ "$(git ls-remote "https://github.com/$FORK.git" "refs/heads/$BRANCH" | cut -f1)" = "$sha" ] \
  || die "push $BRANCH to the fork first: git push fork $BRANCH"
conclusion="$(gh run list -R "$FORK" -w upstream-gate.yml -L 50 --json displayTitle,conclusion \
  -q "[.[] | select(.displayTitle | endswith(\"@ $sha\"))][0].conclusion")"
[ "$conclusion" = success ] \
  || die "no passing upstream-gate run for ${sha:0:12} (got: ${conclusion:-none}) — run fork/upstream-check.sh"
echo "✓ upstream-gate passed for ${sha:0:12}"

title="$(git log -1 --format=%s "$(git rev-list --reverse "origin/main..$BRANCH" | head -1)")"
read -r -p "Open '$title' on $UPSTREAM from $FORK:$BRANCH? [y/N] " answer
[ "$answer" = y ] || exit 1
gh pr create -R "$UPSTREAM" --base main --head "ajchemist:$BRANCH" --title "$title" --body-file "$BODY"
