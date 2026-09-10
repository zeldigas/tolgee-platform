#!/usr/bin/env bash
#
# Merges tolgee/tolgee-platform's main branch into this fork's feature/no_ee
# branch, strips EE-only content (ee/backend, webapp/src/ee) back out, and
# pushes the result (with tags) to origin.
#
# Usage:
#   .github/merge_upstream.sh [--continue] [--skip-build-check] [--no-push] [--dry-run]

set -euo pipefail

UPSTREAM_REMOTE="upstream"
UPSTREAM_URL="https://github.com/tolgee/tolgee-platform.git"
UPSTREAM_BRANCH="main"
ORIGIN_REMOTE="origin"
TARGET_BRANCH="feature/no_ee"
WORK_BRANCH="upstream-sync"
EE_PATHS=(ee webapp/src/ee)

CONTINUE=false
SKIP_BUILD_CHECK=false
NO_PUSH=false
DRY_RUN=false

for arg in "$@"; do
  case "$arg" in
    --continue) CONTINUE=true ;;
    --skip-build-check) SKIP_BUILD_CHECK=true ;;
    --no-push) NO_PUSH=true ;;
    --dry-run) DRY_RUN=true; NO_PUSH=true ;;
    *)
      echo "ERROR: unknown argument '$arg'" >&2
      exit 1
      ;;
  esac
done

log() { echo "==> $*"; }
err() { echo "ERROR: $*" >&2; }

repo_root="$(git rev-parse --show-toplevel)"
cd "$repo_root"

# ---------------------------------------------------------------------------
# 1. Preflight
# ---------------------------------------------------------------------------

if ! git remote get-url "$UPSTREAM_REMOTE" >/dev/null 2>&1; then
  log "Adding missing remote '$UPSTREAM_REMOTE' -> $UPSTREAM_URL"
  git remote add "$UPSTREAM_REMOTE" "$UPSTREAM_URL"
fi

if $CONTINUE; then
  current_branch="$(git branch --show-current)"
  if [ "$current_branch" != "$WORK_BRANCH" ]; then
    err "--continue requires '$WORK_BRANCH' to be checked out (currently on '$current_branch')."
    err "Run: git checkout $WORK_BRANCH  (fetch it first with: git fetch $ORIGIN_REMOTE $WORK_BRANCH)"
    exit 1
  fi
  if [ -n "$(git status --porcelain)" ]; then
    err "Working tree isn't clean. Finish resolving and commit your fix before running --continue."
    git status --short
    exit 1
  fi
  if [ -f "$repo_root/.git/MERGE_HEAD" ]; then
    err "A merge is still in progress (MERGE_HEAD present). Finish committing it first."
    exit 1
  fi
else
  if [ -n "$(git status --porcelain)" ]; then
    err "Working tree isn't clean. Commit or stash your changes before running this script."
    git status --short
    exit 1
  fi
fi

# ---------------------------------------------------------------------------
# 2. Fetch + branch + merge (skipped on --continue)
# ---------------------------------------------------------------------------

if ! $CONTINUE; then
  log "Fetching $UPSTREAM_REMOTE/$UPSTREAM_BRANCH (with tags)..."
  git fetch "$UPSTREAM_REMOTE" --tags "$UPSTREAM_BRANCH"

  log "Updating local $TARGET_BRANCH..."
  git checkout "$TARGET_BRANCH"
  git pull --ff-only "$ORIGIN_REMOTE" "$TARGET_BRANCH"

  if git show-ref --verify --quiet "refs/heads/$WORK_BRANCH"; then
    log "Removing stale local '$WORK_BRANCH' branch..."
    git branch -D "$WORK_BRANCH"
  fi

  log "Creating work branch '$WORK_BRANCH' from '$TARGET_BRANCH'..."
  git checkout -b "$WORK_BRANCH" "$TARGET_BRANCH"

  log "Merging $UPSTREAM_REMOTE/$UPSTREAM_BRANCH into $WORK_BRANCH..."
  merge_failed=false
  git merge --no-ff --no-edit "$UPSTREAM_REMOTE/$UPSTREAM_BRANCH" || merge_failed=true

  if $merge_failed; then
    # -------------------------------------------------------------------
    # 3. Conflict triage
    # -------------------------------------------------------------------
    mapfile -t conflicted < <(git diff --name-only --diff-filter=U)

    ee_conflicts=()
    other_conflicts=()
    for f in "${conflicted[@]}"; do
      case "$f" in
        ee/*|webapp/src/ee/*) ee_conflicts+=("$f") ;;
        *) other_conflicts+=("$f") ;;
      esac
    done

    if [ "${#ee_conflicts[@]}" -gt 0 ]; then
      log "Auto-resolving ${#ee_conflicts[@]} conflict(s) under ee/ or webapp/src/ee/ by deletion..."
      git rm -rf -- "${ee_conflicts[@]}" >/dev/null
    fi

    # Sweep for any ee content that merged in cleanly (no conflict) too.
    git rm -rf --ignore-unmatch -- "${EE_PATHS[@]}" >/dev/null

    if [ "${#other_conflicts[@]}" -gt 0 ]; then
      log "Committing merge with ${#other_conflicts[@]} unresolved conflict(s) outside ee/ paths..."
      {
        echo "Merge upstream/main into $WORK_BRANCH (UNRESOLVED CONFLICTS)"
        echo
        echo "The following files still contain conflict markers and need manual resolution:"
        for f in "${other_conflicts[@]}"; do
          echo "  - $f"
        done
        echo
        echo "After fixing them: git add <files>, git commit, then re-run"
        echo ".github/merge_upstream.sh --continue"
      } > /tmp/merge_upstream_commit_msg.txt
      git add -A
      git commit -F /tmp/merge_upstream_commit_msg.txt
      rm -f /tmp/merge_upstream_commit_msg.txt

      if ! $NO_PUSH; then
        log "Pushing '$WORK_BRANCH' to $ORIGIN_REMOTE so this state isn't lost..."
        git push --force "$ORIGIN_REMOTE" "$WORK_BRANCH" || err "Failed to push $WORK_BRANCH (continuing to report locally)."
      fi

      err "Merge stopped: ${#other_conflicts[@]} file(s) outside ee/ need manual resolution:"
      for f in "${other_conflicts[@]}"; do
        echo "  - $f" >&2
      done
      err "Fix them on '$WORK_BRANCH', commit, then re-run: .github/merge_upstream.sh --continue"
      exit 1
    fi

    log "All conflicts were confined to ee/ paths and are resolved. Finishing merge commit..."
    git commit --no-edit
  else
    # Merge succeeded outright; still sweep for cleanly-added ee content.
    git rm -rf --ignore-unmatch -- "${EE_PATHS[@]}" >/dev/null
    if [ -n "$(git status --porcelain)" ]; then
      git commit --amend --no-edit
    fi
  fi
else
  # Resuming: re-sweep in case the manual fix-up commit reintroduced ee
  # content (e.g. by re-adding a file while resolving an unrelated conflict).
  # Harmless no-op if there's nothing left to remove.
  git rm -rf --ignore-unmatch -- "${EE_PATHS[@]}" >/dev/null
  if [ -n "$(git status --porcelain)" ]; then
    git commit --amend --no-edit
  fi
fi

# ---------------------------------------------------------------------------
# 6. Build sanity check
# ---------------------------------------------------------------------------

if ! $SKIP_BUILD_CHECK; then
  log "Regenerating webapp ee/oss module symlink..."
  node webapp/scripts/prepareEe.js

  log "Running backend compile check..."
  build_failed=false
  ./gradlew compileKotlin compileTestKotlin -x test --console=plain || build_failed=true

  if ! $build_failed; then
    log "Running frontend typecheck..."
    npm run --prefix webapp tsc || build_failed=true
  fi

  if $build_failed; then
    if ! $NO_PUSH; then
      log "Pushing '$WORK_BRANCH' to $ORIGIN_REMOTE so this state isn't lost..."
      git push --force "$ORIGIN_REMOTE" "$WORK_BRANCH" || err "Failed to push $WORK_BRANCH (continuing to report locally)."
    fi
    err "Build check failed after removing ee content."
    err "This usually means a leftover file outside ee/ still references removed EE code (see commit ced20a8d1 for the pattern)."
    err "Find and remove/fix the offending file(s) on '$WORK_BRANCH', commit, then re-run: .github/merge_upstream.sh --continue"
    exit 1
  fi
else
  log "Skipping build sanity check (--skip-build-check)."
fi

# ---------------------------------------------------------------------------
# 7. Fast-forward target branch
# ---------------------------------------------------------------------------

target_before="$(git rev-parse "$TARGET_BRANCH")"

log "Fast-forwarding $TARGET_BRANCH to $WORK_BRANCH..."
git checkout "$TARGET_BRANCH"
git merge --ff-only "$WORK_BRANCH"
git branch -d "$WORK_BRANCH"

# ---------------------------------------------------------------------------
# 8. Push
# ---------------------------------------------------------------------------

log "Merged commits:"
git log --oneline "$target_before..$TARGET_BRANCH" || true

if $DRY_RUN; then
  log "[dry-run] Would push $TARGET_BRANCH and tags to $ORIGIN_REMOTE now."
  exit 0
fi

if $NO_PUSH; then
  log "Skipping push (--no-push). Run 'git push $ORIGIN_REMOTE $TARGET_BRANCH --tags' manually when ready."
  exit 0
fi

log "Pushing $TARGET_BRANCH to $ORIGIN_REMOTE..."
git push "$ORIGIN_REMOTE" "$TARGET_BRANCH"

log "Pushing tags to $ORIGIN_REMOTE..."
git push "$ORIGIN_REMOTE" --tags

log "Cleaning up any stale '$WORK_BRANCH' branch on $ORIGIN_REMOTE (from a previously failed run)..."
git push "$ORIGIN_REMOTE" --delete "$WORK_BRANCH" >/dev/null 2>&1 || true

log "Done. $TARGET_BRANCH and tags pushed to $ORIGIN_REMOTE."
