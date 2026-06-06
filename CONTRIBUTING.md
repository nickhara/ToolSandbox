# Contributing to ToolSandbox

Thanks for working on this repo! To keep history clean and PR review fast, we
enforce two conventions for **all** changes:

1. **Conventional Commits** for every commit message and every PR title.
2. **Feature branches + PRs** — no direct pushes to `main`.

Both are checked automatically by `.github/workflows/pr-conventions.yml` on
every pull request.

---

## 1. Conventional Commits

Every commit message and every PR title must follow this format:

```
<type>(<optional scope>): <short summary in the imperative mood>

<optional body explaining what & why, wrapped at ~72 chars>

<optional footer(s) — BREAKING CHANGE:, Refs:, Closes:, Co-authored-by:, etc.>
```

### Allowed types

| Type | Use for |
|---|---|
| `feat` | A new user-facing feature or capability |
| `fix` | A bug fix |
| `chore` | Maintenance, dependency bumps, tooling, repo housekeeping |
| `docs` | Documentation-only changes |
| `refactor` | Code change that neither fixes a bug nor adds a feature |
| `test` | Adding or correcting tests |
| `perf` | Performance improvement |
| `build` | Build system or external dependencies (csproj, packages, etc.) |
| `ci` | CI configuration (`.github/workflows/**`, dependabot, etc.) |
| `revert` | Reverts a previous commit |

### Scopes (optional but encouraged)

Use the top-level project folder when applicable, e.g.:

- `feat(docker-cleanup): add aggressive mode flag`
- `fix(dfs-cleanup): handle null target list`
- `chore(deps): bump xunit to 2.10.0`
- `ci(dependabot): tighten weekly schedule`

### Breaking changes

Either append `!` after the type/scope **or** include a `BREAKING CHANGE:`
footer:

```
feat(dfs-cleanup)!: drop support for .NET 8

BREAKING CHANGE: TargetFramework moved to net10.0 only.
```

### Examples (good)

```
feat(winget-updater): add --exclude-package CLI flag
fix(dfs-cleanup): retry transient WinRM failures
chore(deps): add Dependabot configuration
docs(docker-cleanup): document -IncludeVolumes safety model
ci: lint PR titles for Conventional Commits compliance
```

### Examples (rejected)

```
Updated stuff                 ← no type
Fix bug                       ← capitalized verb, no scope, no specifics
WIP                           ← no type, no information
feat: Add Feature.            ← trailing period, capitalized summary
```

---

## 2. Feature branches & PR workflow

### Branch naming

All work branches must match this regex:

```
^(feat|fix|chore|docs|refactor|test|perf|build|ci|revert)/[a-z0-9._\-/]+$
```

Examples:

- `feat/docker-cleanup-aggressive-mode`
- `fix/dfs-cleanup-null-target-list`
- `chore/dependabot-config`
- `ci/pr-conventions-workflow`

The type prefix should match (or at least be compatible with) the type of the
commits on the branch.

### Workflow

1. Create a feature branch off the latest `origin/main`:
   ```powershell
   git fetch origin
   git switch -c <type>/<short-description> origin/main
   ```
2. Make your changes. Each commit message must follow Conventional Commits.
3. Push and open a PR targeting `main`:
   ```powershell
   git push -u origin <branch-name>
   gh pr create --base main --fill
   ```
4. The `pr-conventions` workflow validates the PR title and branch name. Fix
   any failures and push again.
5. Use **Squash and merge** to land. The PR title becomes the squashed commit
   message on `main` — so a valid PR title is the contract.
6. Delete the branch after merge.

### Direct pushes to `main` are not allowed

Even if branch protection isn't yet enabled in repo settings, do not push
directly to `main`. To make this a hard rule, the repo admin should enable
GitHub branch protection / rulesets on `main`:

- **Require a pull request before merging** (≥ 0 reviewers is OK for solo work)
- **Require status checks to pass before merging** → select the
  `pr-conventions / pr-conventions-check` check from the workflow added in
  this PR
- **Restrict deletions** and **Block force pushes** on `main`

GitHub UI path: **Settings → Branches → Add branch protection rule**, or the
newer **Settings → Rules → Rulesets**.

---

## 3. Tools that help

- **`gh` CLI** for opening PRs: `winget install GitHub.cli`
- **Commit message linting locally** (optional): point your editor at this
  doc, or install [commitizen](https://commitizen-tools.github.io/commitizen/)
  if you prefer an interactive prompt.
- **Pull request template** at `.github/PULL_REQUEST_TEMPLATE.md` prefills the
  expected structure on every new PR.
