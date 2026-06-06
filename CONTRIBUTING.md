# Contributing to ToolSandbox

This is a small personal-tooling repo. The goal of this doc is to keep history
readable and PRs easy to skim — **not** to enforce process for its own sake.
Treat everything below as guidelines. Use judgement; if a rule would slow you
down without helping anyone, skip it and move on.

## TL;DR

- Write commit/PR titles like `feat: short imperative summary` (see
  [Conventional Commits](https://www.conventionalcommits.org/en/v1.0.0/) for
  the spec).
- Prefer a short-lived branch + squash-merged PR over pushing to `main`. For
  truly trivial edits (typo, comment, `.gitignore`, dependabot follow-up),
  a direct push to `main` is fine.
- The only automated check is the **PR title** — because squash-merge promotes
  it verbatim to `main`. Branch names are a soft suggestion.

## Commit / PR title format

```
<type>: <short summary in the imperative mood>
<type>(<scope>): <short summary>          # scope is optional
```

Common types: `feat`, `fix`, `chore`, `docs`, `refactor`, `ci`. Other
Conventional Commits types (`test`, `perf`, `build`, `revert`) are accepted if
they fit better — pick whatever's clearest.

Scopes are a hint, not a requirement. Use one when it helps a reader narrow
down what changed, e.g. `feat(winget-updater): ...`.

Breaking changes: add `!` after the type, e.g. `feat!: drop .NET 8 support`.

### Good

```
feat(winget-updater): add --exclude-package flag
fix(dfs-cleanup): retry transient WinRM failures
chore(deps): bump xunit to 2.10.0
docs: clarify Dependabot grouping
```

### Avoid

```
Updated stuff          # no type, not skimmable
WIP                    # no information
Fix Bug.               # capitalized, trailing period, no specifics
```

## Branches & PRs

- Branch off the latest `origin/main`. Name it something obvious.
  `feat/winget-utf8-fix` is great. `nick-test-2` is fine for a throwaway.
- A prefix matching the change type (`feat/`, `fix/`, `chore/`, …) is
  encouraged because it sorts nicely in `git branch -a`. Not enforced.
- Open a PR, squash-merge, delete the branch. The PR title is the commit on
  `main`, so make it good.

### Fast path for trivial changes

These don't need a branch or PR:

- Typos and comment fixes
- `.gitignore` additions
- README clarifications that don't change behavior
- Routine dependency bumps via Dependabot auto-merge

For everything else, prefer a PR — it gives you a second pair of eyes (even if
that pair of eyes is just future-you reading the diff before merging).

## Branch protection (recommended, not required)

If you want to make the "no direct pushes to `main`" preference a hard rule,
enable branch protection in **Settings → Rules → Rulesets**:

- Require a PR before merging (0 reviewers is fine for solo work)
- Require the `pr-conventions / pr-conventions-check` status check
- Block force pushes on `main`

## Tools

- **`gh` CLI**: `winget install GitHub.cli` — for `gh pr create` / review
- PR template at `.github/PULL_REQUEST_TEMPLATE.md` (intentionally tiny)
