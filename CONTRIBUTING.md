# Contributing

DeckCheck is a small, single-maintainer project. These are the conventions that keep
`main` readable now that the repo is public — and, just as importantly, how to keep
them from getting in the way of the edit → build → poke-at-it-on-the-phone loop.

## The short version

- **Never commit to `main`.** Branch, then open a PR, then **squash-merge**.
- **Be as messy as you want on a branch.** It collapses to one commit on merge.
- **One commit on `main` per change**, with a message that says what changed and why.
- **Run `tools/check.sh` before you push.** It's what CI runs.

## Branches

```sh
git switch -c fix/energy-symbol-parsing     # off an up-to-date main
```

Prefix with the same word you'll use in the commit type: `fix/`, `feat/`, `perf/`,
`docs/`, `chore/`, `refactor/`, `test/`, `ci/`.

Keep a branch to one concern. Two unrelated fixes in one branch means one squashed
commit that can't be reverted independently — which is the thing squash-merging is
supposed to buy you.

## Commit messages

[Conventional Commits](https://www.conventionalcommits.org/): `type(scope): subject`.

```
fix(gapcheck): treat "Basic {R} Energy" as basic energy

TCG Live writes basic energy with the type symbol rather than the word, so
BasicEnergy.match fell through to set-code resolution, resolved MEE 2 to Fire
Energy, and reported it as 5 missing instead of auto-satisfied.
```

- **type** — `feat` · `fix` · `perf` · `refactor` · `test` · `docs` · `ci` · `chore`
- **scope** — the area, not the file: `gapcheck`, `catalog`, `sheets`, `scan`,
  `cards`, `decks`, `images`, `oauth`
- **subject** — imperative, lowercase, no trailing period, ≤ 72 chars
- **body** — optional, and worth it whenever the *why* isn't obvious from the diff.
  Wrap at 72. This is the part future-you actually reads.

Add `BREAKING CHANGE:` in the body for anything that invalidates a user's existing
data — in this repo that means primarily a `NORM_VERSION` bump, which invalidates
every `equivalence_key` already written into people's Sheets.

## How this affects testing on device

The tension is real: the engines test in seconds on the laptop, but "does it actually
feel right" needs a build on a physical iPhone, which is slow and can't be automated.
Squash-merging is what resolves it. **The branch is your scratchpad; only the merge is
public.** So:

**Commit before you go to the device, not after.** Get it compiling, run the core
tests, commit. Then build to the phone. If the phone reveals a problem, you fix it as
a *second* commit on the same branch — and because the branch squashes, `main` still
sees one clean change. You never have to choose between a tidy history and a tight
feedback loop.

Rewriting an unmerged topic branch is free here — nobody else has it. `git commit
--amend`, `git rebase -i`, and `git push --force-with-lease` are all fair game right
up until the PR merges. After it merges, leave history alone.

Two things worth knowing about the device loop specifically:

- **Free-provisioning builds stop launching after 7 days.** That's an Apple signing
  limit, not a repo problem — re-run from Xcode to refresh. It has no bearing on what
  you commit.
- **The catalog is not in git.** `ios/DeckCheck/catalog.sqlite` is a build artifact you
  generate. A fresh clone has no catalog, so `Cards → All`, the scan picker, and the
  gap-check all come up empty until you run the builder. If you're testing a change to
  resolution or equivalence, rebuild the catalog first — a stale snapshot will make a
  correct change look broken.

## Before you push

```sh
tools/check.sh
```

Core tests plus an app compile — the same two jobs as CI, so a green run locally means
a green PR. Roughly a minute cold, seconds warm.

Neither one launches the app. Nothing in CI can tell you whether the scan flow feels
right or whether images pop in smoothly; that's what the phone is for. What CI *does*
guarantee is that a change to the pure engines in `DeckCheckCore` is correct — which is
why non-trivial logic belongs there rather than in a SwiftUI view. Anything you push
down into `DeckCheckCore` is something you stop having to re-verify by hand.

## What must never be committed

Already covered by `.gitignore`, but worth knowing *why* — these are the ones that
would matter:

| Path | Why |
|---|---|
| `ios/DeckCheck/catalog.sqlite` | Third-party card data. The repo ships the recipe, never the meal. |
| `ios/Config/Local.xcconfig` | Your Apple Team ID and bundle identifier. |
| Card images, of any kind | Same as the catalog — not ours to redistribute. |

Your bundle identifier and Team ID both live in `Local.xcconfig` and reach the build
through `Config/Signing.xcconfig`. `project.pbxproj` refers to them only as
`$(DECKCHECK_BUNDLE_ID)` / the `DEVELOPMENT_TEAM` xcconfig setting, so setting up your
own copy leaves no diff in a tracked file.

**Xcode still touches `project.pbxproj` on its own** — adding a file, or sometimes just
opening the project, rewrites file-reference comments. Before committing it, check
whether the diff is real:

```sh
git diff ios/DeckCheck.xcodeproj/project.pbxproj
```

If every hunk is a renamed `/* comment */` and nothing else, discard it —
`git checkout -- ios/DeckCheck.xcodeproj/project.pbxproj`. If it adds a build file or
changes a setting, commit it as `chore(xcode):` on its own.

## Where code goes

`DeckCheckCore` holds the pure engines — resolve, gap-check, search, the
Sheets/OAuth/Apps-Script request builders — and is heavily unit-tested. The SwiftUI
app in `ios/DeckCheck/` stays a thin shell over them.

When you add behaviour, ask whether it can be a function over values instead of a
method on a view. If it can, it belongs in `DeckCheckCore` with a test, and you get to
verify it without a phone in your hand.
