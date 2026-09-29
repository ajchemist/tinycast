# Fork tooling (`personal` only)

This directory, `personal-release.yml` and `upstream-gate.yml` exist only on this fork's `personal`
branch. They never go upstream, and `upstream-guard.sh` fails a branch that carries them.

## Two kinds of branch

| Branch | Cut from | Goes to |
| --- | --- | --- |
| `personal` | itself; upstream `main` is merged in nightly | Tinycast Personal releases |
| `fix/<issue>-…`, `feat/<issue>-…` | upstream `main` | a PR on abue-ammar/tinycast |

A change meant for upstream is written on its own branch first, then cherry-picked onto `personal`,
never the other way round. That keeps the upstream branch free of fork-only commits.

## What upstream demands

From `CONTRIBUTING.md`, `AGENTS.md` and what the maintainer has said on issues:

- **An `approved` issue before any code is shared.** A PR without `Closes #N` for an approved issue
  is closed automatically on open. Docs-only changes are exempt.
- **An extension fix stays inside `Tinycast/Features/Extensions/`.** No palette file
  (`Tinycast/Palette/`), no `DesignSystem/`, no core file, even for one line. The maintainer rejected
  #887 and #1181's first fix (#1111) for exactly this. Reach the palette through the hooks it
  already exposes (`PaletteScreen`, `ExtensionCoordinator`'s `palette` writes).
- **No AI attribution** in commits or PR bodies. Upstream's `coauthors.yml` blocks the merge.
- Rebased on `main`, squashed into logical commits with imperative subjects.
- Harnesses, lint, Model purity and a clean Debug build with **zero new warnings**. Upstream has no
  CI, so this is on us.
- Leak-tested, with idle and peak memory numbers in the PR (under 100 MB).
- A side-by-side before/after video for any visual change.
- Docs the change made wrong are fixed in the same commit.

## Workflow

```sh
git fetch origin && git switch -c fix/1181-short-name origin/main
# …commit…
fork/upstream-guard.sh                  # static checks, seconds
fork/upstream-check.sh                  # guard, push to the fork, then build + harnesses + lint on macOS
git switch personal && git cherry-pick <sha> && git push fork personal   # try it in Tinycast Personal
fork/upstream-pr.sh 1181 pr-body.md fix/1181-short-name   # refuses until #1181 is approved
```

`upstream-pr.sh` checks the approved label, the PR template (with `Closes #N` and the memory
table), the guard and a passing `upstream-gate` run for the exact commit, then asks before it opens
the PR.
