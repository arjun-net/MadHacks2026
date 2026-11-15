# MadHacks2026 — Branching and Contribution Guide

> **Repository:** [arjun-net/MadHacks2026](https://github.com/arjun-net/MadHacks2026)  
> **Project:** Campus Pulse / Badger Pulse  
> **For:** iOS, Rust backend, Databricks integration, tests, and documentation  
> **Guide prepared:** November 15, 2026

## 1. Scope and verification

This guide is designed for contributors to the MadHacks2026 repository. It combines **source-observed project structure** with a **recommended Git workflow**. These are different things:

- **Inspected snapshot:** An available `MadHacks2026-main.zip` export, dated approximately November 14, 2026. It contains the SwiftUI iOS application (`CampusPulse.xcodeproj`, `CampusPulse/`, and `CampusPulseTests/`). It does **not** contain Git branch references or the Rust backend.
- **Previously used branch:** `rust-backend` has been used for the Rust/Axum + Databricks backend during development. Its **current remote state is not verified** by this document.
- **Live inventory:** The GitHub URL could not be read publicly while preparing this guide. **The names, default-branch setting, protection rules, and current merge status of all remote branches must be confirmed** using the commands in Section 3. Do not interpret the examples in this guide as an authoritative current branch list.

If GitHub is private, run the commands from a checkout with repository access. This document does not change repository settings or create branches.

## 2. What belongs where

### 2.1 Project areas observed in the `main` snapshot

| Area | Representative paths | Notes |
| --- | --- | --- |
| iOS app | `CampusPulse.xcodeproj`, `CampusPulse/App/` | SwiftUI application entry point and app configuration. |
| Mobile screens | `CampusPulse/Views/` | Map, activity, sharing, onboarding, and settings. |
| Map/heatmap | `CampusPulse/Heatmap/` | Heatmap grid and map rendering. |
| Location collection | `CampusPulse/Location/` | Location provider and queued observations. |
| API integration | `CampusPulse/Networking/LocationAPI.swift`, `HeatmapAPI.swift` | Mobile clients for backend location and heatmap endpoints. |
| App state | `CampusPulse/State/`, `CampusPulse/ViewModels/` | App preferences, snapshots, and view models. |
| iOS tests | `CampusPulseTests/` | Includes aggregation and sharing tests. |
| Project documentation | `README.md` | May need updating as features move across branches. |

The snapshot's README describes the app as “UI only,” **but the snapshot also contains networking and location client source files**. Treat that README statement as potentially stale; verify real behavior and update it during integration.

### 2.2 Rust and Databricks work

The Rust backend discussed during development is an Axum/SQLx service with location ingestion, building identification, historical stories, and predictions through Databricks Lakebase and a SQL Warehouse. Relevant paths **in that backend line of work** include:

- `src/main.rs`, `src/routes.rs`, `src/store.rs`, `src/story.rs`, `src/prediction.rs` (confirm exact paths in your checked-out branch).
- `tests/` for HTTP and live integration tests.
- `scripts/` for synthetic Lakebase datasets and cleanup.
- `Cargo.toml` for Rust builds.

These are **not verified to be present on the `main` snapshot**. Before running Rust commands, switch to a branch or worktree containing `Cargo.toml`.

### 2.3 Databricks is not a Git branch

- **Git branches** isolate application source-code changes (`main`, `rust-backend`, feature branches).
- **Lakebase database branches** isolate database data and schema. A Lakebase branch named `primary` is **not** the Git branch named `main`.
- **Unity Catalog** registers the Lakebase data for analytical SQL access. **SQL Warehouses** execute queries; those are services, not source-control branches.

Keep test data on a development Lakebase branch when possible. Never assume that switching Git branches also changes your database target; environment variables choose that separately.

## 3. Discover the repository's actual branches (do this first)

From a cloned repository in PowerShell:

```powershell
# If the repository has not been cloned yet:
git clone https://github.com/arjun-net/MadHacks2026.git
cd MadHacks2026

# Update remote-tracking references; --prune removes stale local tracking refs.
git fetch origin --prune

# Confirm the remote and currently checked-out branch.
git remote -v
git status -sb

# Find the default branch if origin/HEAD is configured.
git symbolic-ref --short refs/remotes/origin/HEAD

# List LOCAL and REMOTE branches.
git branch -vv
git branch -r

# Show last activity on each remote branch.
git for-each-ref refs/remotes/origin `
  --sort=-committerdate `
  --format='%(refname:short) | %(committerdate:short) | %(authorname) | %(subject)'

# Visualize the recent history across all available refs.
git log --all --graph --oneline --decorate -30
```

If `origin/HEAD` is not set, use `git remote show origin` to inspect the remote's **HEAD branch**, or consult GitHub's repository Settings. Do not assume `main` is the default merely because an archive is named `MadHacks2026-main.zip`.

**GitHub UI:** Repository → branch selector → **View all branches**, or visit the [branches page](https://github.com/arjun-net/MadHacks2026/branches) while signed into an authorized account.

### 3.1 Working branch inventory (fill from the command output)

| Branch | Classification | Verified role | Merge target | Notes |
| --- | --- | --- | --- | --- |
| `main` | Observed archive name | SwiftUI app snapshot; **remote default status unverified** | Usually default/integration branch; confirm | Contains an Xcode project in the available snapshot. |
| `rust-backend` | Previously used during development | Rust API, Lakebase/Databricks work; **current remote contents unverified** | Confirm with team | Compare with the actual default before merging. |
| *(other remote branches)* | To be discovered | Run Section 3 | Confirm individually | Do not invent branch roles from names alone. |

To inspect another branch without replacing your current checkout:

```powershell
git fetch origin
# Example only; run if origin/rust-backend exists.
git log -5 --oneline origin/rust-backend
git diff --stat origin/main...origin/rust-backend
git diff --name-status origin/main...origin/rust-backend
```

The `A...B` form focuses on changes since the common ancestor; it is often appropriate for reviewing a proposed merge. If `origin/main` is not the actual default branch, substitute the correct base.

## 4. Recommended branching model

For a small hackathon team, use **one stable integration branch plus short-lived feature branches**, not a complex Git Flow release hierarchy.

```text
<default integration branch, e.g. main>
  ├── feature/ios-activity-cards
  ├── feature/backend-prediction
  ├── fix/story-validation
  ├── docs/api-guide
  └── test/databricks-fixtures

existing rust-backend (if still active)
  └── compare and integrate into default through a reviewed PR
```

**Proposed naming rules (not evidence of existing branches):**

| Prefix | Purpose | Example |
| --- | --- | --- |
| `feature/` | New app or server functionality | `feature/ios-predictions` |
| `fix/` | Bug fixes | `fix/story-no-data` |
| `refactor/` | Behavior-preserving cleanup | `refactor/observation-counts` |
| `test/` | Fixtures and test coverage | `test/sql-story-fixtures` |
| `docs/` | README and developer instructions | `docs/branching-guide` |
| `chore/` | Configuration and maintenance | `chore/gitignore-secrets` |
| `hotfix/` | Urgent stabilization | `hotfix/health-endpoint` |

Prefer lowercase kebab-case and short, descriptive names. If the team retains `rust-backend` as a temporary integration branch, use it intentionally, document its ownership, and avoid treating it as a permanent second default branch unless there is a reason.

## 5. Everyday Git workflow (PowerShell)

### 5.1 Before touching code

```powershell
git status -sb
git fetch origin --prune
git branch -r
```

If you have uncommitted changes, commit them on the appropriate branch or temporarily stash them with `git stash push -u -m "WIP before switching"` before switching. **Review what is stashed** before deleting it.

### 5.2 Create a feature branch from the confirmed default

```powershell
git switch main                  # Substitute the actual default if needed
git pull --ff-only origin main
git switch -c feature/ios-predictions
```

If a feature depends on changes not yet merged from `rust-backend`, agree on a base with teammates and document that dependency in the pull request. Avoid casually stacking independent features on unmerged work.

### 5.3 Stage, inspect, commit, and publish

```powershell
git status
git diff
git add CampusPulse/           # Prefer specific paths over accidental git add .
git diff --cached --stat
git diff --cached
git commit -m "feat(ios): add prediction insight card"
git push -u origin feature/ios-predictions
```

Good commit examples:

- `feat(api): expose building prediction endpoint`
- `fix(story): reject unsupported AI claims`
- `test(sql): cover repeated device identifiers`
- `docs: add branch and contribution guide`

Make commits small enough to review and test. Do not commit generated databases, credentials, build outputs, or unrelated refactors.

### 5.4 Open a pull request

In GitHub, choose **Compare & pull request** for the pushed branch. Verify both:

- **Base**: confirmed integration/default branch (often `main`).
- **Compare**: your feature branch.

Include a summary, files/areas changed, testing evidence, API/schema compatibility, screenshots for SwiftUI changes, and any Databricks setup needed. Request at least one reviewer when possible.

### 5.5 Update an open branch

For a **personal feature branch** with no other contributors basing work on it:

```powershell
git fetch origin
git switch feature/ios-predictions
git rebase origin/main
# Resolve conflicts if prompted, then:
git rebase --continue
# Only if rebasing changed commits that were already pushed:
git push --force-with-lease
```

**Do not rebase/force-push a shared integration branch** without explicit agreement. On shared branches, prefer merging the updated base instead, or let GitHub perform the final PR merge.

A rejected push (`non-fast-forward`) means the remote has work you do not have locally. **Fetch and inspect first**:

```powershell
git fetch origin
git log --oneline --left-right --graph HEAD...origin/rust-backend
```

If it is your own feature branch and its upstream should be incorporated, `git pull --rebase` may be appropriate. For team-shared `rust-backend`, coordinate before rewriting history. Never use unqualified `git push --force` as a routine fix.

## 6. Pull request and merge standards

Before approving a pull request, confirm:

- Changes are scoped and clearly described; the PR targets the correct base branch.
- Swift and Rust clients agree on endpoint URLs, field names, status codes, and JSON types.
- API behavior changes have unit or integration tests; UI behavior changes have build/test evidence.
- Test datasets are clearly synthetic, isolated, and reproducible.
- No secrets, Databricks personal-access tokens, database passwords, actual `.env` files, device identifiers, or private location datasets appear in the diff.
- Privacy wording distinguishes **location observations** from unique people or verified occupancy.
- Databricks migrations and SQL instructions document whether they apply to **Lakebase PostgreSQL** or **Databricks SQL Warehouse**.
- The README and API documentation have been updated if user-visible behavior changed.

**Recommended merge strategy:** Squash-merge small feature PRs into the integration branch; use conventional merge commits when preserving an intentionally meaningful shared history. Choose one team convention, enforce it consistently, and avoid mixing unrelated changes into one PR.

### Branch protection to enable on GitHub (recommendation, not confirmed current settings)

For the default branch: require a pull request, at least one approval when the team size allows, passing required checks once CI exists, and block force pushes/deletions. Consider CODEOWNERS for cross-cutting API and data-contract changes. If settings are unavailable under your plan, follow the same policy manually.

## 7. Building and testing each part

### 7.1 SwiftUI application

From a branch containing `CampusPulse.xcodeproj`:

```bash
# On macOS with Xcode installed:
open CampusPulse.xcodeproj
xcodebuild -list -project CampusPulse.xcodeproj
xcrun simctl list devices available
```

Open the `CampusPulse` scheme in Xcode and run its tests on an available iOS simulator. The inspected README specifies Xcode 26+, iOS 17+, and no third-party dependencies for its snapshot. Verify that these requirements still apply on the branch being merged.

### 7.2 Rust backend

From a branch containing `Cargo.toml`:

```powershell
cargo fmt --all -- --check
cargo clippy --all-targets -- -D warnings
cargo test
cargo run --bin madhacks-backend
```

`cargo run --bin madhacks-backend` is explicit because the backend also has a `build_building_grid` utility binary in development. If Clippy warnings are not yet clean, document them rather than silently bypassing a required check.

### 7.3 Live Databricks integration

```powershell
# Requires the Rust API to be running and the selected test data to exist.
cargo test --test live_prediction -- --ignored --nocapture
cargo test --test live_story_ai -- --ignored --nocapture
```

These tests are **not substitutes for offline unit tests**. Live tests may require a Databricks SQL Warehouse, a Unity Catalog registration of Lakebase, a model endpoint for AI narration, and suitable data in the branch selected by your environment variables. `STORY_TEST_REQUIRE_AI=1` requires actual model-generated text. Never treat synthetic test counts as real campus population.

## 8. Protect credentials, datasets, and the database

The inspected SwiftUI `.gitignore` excludes Xcode/DerivedData files, but does **not** explicitly list `.env`, `.env.*`, or common Rust build outputs. If the backend is merged into the same repository, add appropriate ignore entries, for example:

```gitignore
# Local credentials and configuration
.env
.env.*
!.env.example

# Rust build artifacts
/target/

# Temporary logs and test output
*.log
```

Keep actual tokens out of `.env.example`; use placeholder values. A `.gitignore` rule **does not remove secrets that were previously committed**. If a password or token is exposed, revoke/rotate it and follow a coordinated secret-removal procedure.

Use separate Lakebase development and production branches/instances where practical. Confirm `DATABASE_URL`, `DATABRICKS_HOST`, `DATABRICKS_WAREHOUSE_ID`, and `DATABRICKS_CATALOG` before running tests or seeding a database. Do not run destructive data scripts against production just because your Git branch says `test/`.

The SwiftUI snapshot's `AppConfig.swift` contains a temporary Cloudflare tunnel URL as its default API base. Such URLs may rotate; do not hardcode short-lived endpoints in release branches. Use environment/build configuration or a stable API hostname.

## 9. Merge the iOS and Rust work safely

The archive available for this guide has an Xcode app but no Rust `Cargo.toml`. The backend was developed separately. To integrate them:

1. Fetch both branches and inspect their differences before merging.
2. Confirm the default branch, decide which branch will host the final integrated project, and open a PR targeting it.
3. Resolve root-level conflicts carefully (`README.md`, `.gitignore`, scripts, documentation).
4. Confirm the Rust app can run alongside the Xcode project without naming/path collisions.
5. Verify the iOS `LocationAPI` and `HeatmapAPI` paths against the Rust `/api/v1/...` routes, including the base URL. The inspected SwiftUI clients append paths like `locations` and `heatmap` to a base ending in `/api/v1`.
6. Verify `/story` and `/prediction` fields consumed by the iOS app. In the recent API design, `story` and `summary` are short strings; other fields expose statistics and historical samples.
7. Reconcile privacy copy and actual aggregation: the latest analytical design counts **rows/observations** rather than deduplicated device IDs; ensure mobile text does not call them students or occupancy.
8. Run SwiftUI and Rust tests; run live warehouse tests only on an isolated known dataset.
9. Update the README so it no longer incorrectly describes the integrated app as UI-only.

Useful pre-merge inspection commands:

```powershell
git fetch origin
# Only if the two named refs exist:
git diff --stat origin/main...origin/rust-backend
git diff --name-status origin/main...origin/rust-backend
git log --oneline --left-right origin/main...origin/rust-backend
```

## 10. Troubleshooting common Git problems

| Problem | Diagnosis | Safe response |
| --- | --- | --- |
| `error: failed to push some refs (non-fast-forward)` | Remote advanced ahead of local | `git fetch`, inspect divergence, integrate remote work; do not blindly force-push. |
| `Your local changes would be overwritten by checkout` | Uncommitted edits conflict with the target branch | Commit, stash, or deliberately discard only confirmed disposable changes. |
| `CONFLICT (content)` | Git cannot merge overlapping edits | Edit conflicted files, remove markers, `git add`, then continue the merge/rebase. |
| `pathspec ... did not match any files known to git` | Name absent or not fetched | `git fetch --prune`, `git branch -a`, check spelling. |
| `cargo run` cannot choose a binary | Multiple Rust binaries exist | `cargo run --bin madhacks-backend`. |
| `Cargo.toml` not found | Not on a Rust-containing branch/root | Check `git status -sb` and `Get-ChildItem Cargo.toml`. |
| App still points to old server | iOS API base URL/tunnel differs | Inspect app `AppConfig.swift` and developer overrides. |
| Database data differs across developers | Git branch != Lakebase database branch | Compare DB endpoint, database branch, catalog/warehouse configuration. |
| Wrong PR comparison | Base and compare selected backward | Confirm `base ← compare` in GitHub before merging. |

**Abort a mistaken in-progress operation:** `git merge --abort` or `git rebase --abort` as applicable. These commands revert the *in-progress Git operation*; they do not necessarily recover unrelated changes you discarded earlier.

## 11. Finishing a feature and cleaning up

After the pull request is merged:

```powershell
git switch main
git pull --ff-only origin main
# Only delete your local branch after verifying it is merged.
git branch -d feature/ios-predictions
# Delete remote branch only if team policy and PR status allow it.
git push origin --delete feature/ios-predictions
```

If `git branch -d` refuses because Git cannot establish merge ancestry, **inspect why rather than immediately using `-D`**. Squash merges change ancestry, so verify the PR was accepted before deleting local work.

## 12. Recommended pull request template

Save this as `.github/pull_request_template.md` if the team wants to adopt it:

```markdown
## What changed?

## Why?

## Components affected
- [ ] SwiftUI
- [ ] Rust API
- [ ] Lakebase PostgreSQL
- [ ] Databricks SQL / Unity Catalog
- [ ] Databricks AI
- [ ] Documentation / tests

## API or schema changes

## Verification
- [ ] Relevant automated tests passed
- [ ] Manual app/API test completed
- [ ] Synthetic data is labeled and isolated
- [ ] No credentials or private location data added

## Screenshots, commands, or sample output

## Known limitations / follow-up tasks
```

## 13. Quick command reference

| Task | Command |
| --- | --- |
| See active branch | `git branch --show-current` |
| See working tree | `git status -sb` |
| Download remote changes | `git fetch origin --prune` |
| List remote branches | `git branch -r` |
| See branch activity | `git for-each-ref refs/remotes/origin --sort=-committerdate` |
| Create feature branch | `git switch -c feature/my-task` |
| Switch to tracked branch | `git switch rust-backend` (if configured locally) |
| Track an existing remote branch | `git switch --track origin/rust-backend` (if not already local) |
| Publish new branch | `git push -u origin feature/my-task` |
| Inspect changed files | `git diff --name-status origin/main...HEAD` |
| Inspect recent history | `git log --oneline --graph --decorate -20` |
| Stash uncommitted work | `git stash push -u -m "WIP"` |
| Restore a stash | `git stash list` then `git stash apply stash@{0}` |
| Stop conflicted rebase | `git rebase --abort` |
| Run Rust tests | `cargo test` (on Rust-containing branch) |

---

### Repository links

- [Repository](https://github.com/arjun-net/MadHacks2026)
- [Branches](https://github.com/arjun-net/MadHacks2026/branches)
- [Pull requests](https://github.com/arjun-net/MadHacks2026/pulls)
- [Compare main and rust-backend](https://github.com/arjun-net/MadHacks2026/compare/main...rust-backend) (only meaningful if both refs exist)
- [GitHub documentation: viewing branches](https://docs.github.com/en/repositories/configuring-branches-and-merges-in-your-repository/managing-branches-in-your-repository/viewing-branches-in-your-repository)
- [GitHub documentation: branches](https://docs.github.com/en/pull-requests/reference/branches)

**Maintenance note:** Refresh Sections 2–3 and 9 when branches are merged or renamed. The branch inventory here is deliberately conservative because a live remote-branch listing was not available when this guide was prepared.
