#!/usr/bin/env bash

set -euo pipefail

workspace="${GITHUB_WORKSPACE}"
repo_https="https://github.com/${GITHUB_REPOSITORY}.git"
repo_auth="https://x-access-token:${GITHUB_TOKEN}@github.com/${GITHUB_REPOSITORY}.git"
target_sha="${CODE_BOOTSTRAP_TARGET_SHA:-${GITHUB_SHA}}"
fallback_ref="${CODE_BOOTSTRAP_FALLBACK_REF:-${GITHUB_REF:-}}"
sync_lfs="${CODE_BOOTSTRAP_SYNC_LFS:-false}"

restore_origin_url() {
  if [ -d "$workspace/.git" ]; then
    git -C "$workspace" remote set-url origin "$repo_https" >/dev/null 2>&1 || true
  fi
}

trap restore_origin_url EXIT

wait_for_shallow_lock_release() {
  local lock_file="$workspace/.git/shallow.lock"
  local max_wait_seconds=30
  local waited_seconds=0

  while [ -f "$lock_file" ]; do
    if command -v lsof >/dev/null 2>&1 && lsof "$lock_file" >/dev/null 2>&1; then
      if [ "$waited_seconds" -ge "$max_wait_seconds" ]; then
        echo "::error::Git lock is still held after ${max_wait_seconds}s: $lock_file"
        return 1
      fi
      echo "::warning::Git lock in use ($lock_file); waiting..."
      sleep 2
      waited_seconds=$((waited_seconds + 2))
      continue
    fi

    echo "::warning::Removing stale git lock file: $lock_file"
    rm -f "$lock_file"
  done
}

fetch_sha_with_lock_recovery() {
  local sha="$1"
  local next_fallback_ref="$2"
  local max_attempts=5
  local attempt=1

  while [ "$attempt" -le "$max_attempts" ]; do
    wait_for_shallow_lock_release || return 1

    if git fetch --no-tags --depth=1 origin "$sha"; then
      return 0
    fi

    if [ -n "$next_fallback_ref" ] && git fetch --no-tags --depth=1 origin "$next_fallback_ref"; then
      return 0
    fi

    if [ "$attempt" -eq "$max_attempts" ]; then
      break
    fi

    echo "::warning::git fetch failed for ${sha} (attempt ${attempt}/${max_attempts}); retrying..."
    sleep 2
    attempt=$((attempt + 1))
  done

  echo "::error::Unable to fetch ${sha} after ${max_attempts} attempts."
  return 1
}

if [ -d "$workspace/.git" ]; then
  cd "$workspace"
  git remote set-url origin "$repo_auth"
  fetch_sha_with_lock_recovery "$target_sha" "$fallback_ref"
  git checkout -f "$target_sha"
  git remote set-url origin "$repo_https"
else
  if [ -d "$workspace" ] && [ -n "$(ls -A "$workspace" 2>/dev/null)" ]; then
    echo "::error::Expected empty workspace before initial clone."
    ls -la "$workspace"
    exit 1
  fi

  mkdir -p "$workspace"
  git clone "$repo_auth" "$workspace"
  cd "$workspace"
  fetch_sha_with_lock_recovery "$target_sha" "$fallback_ref"
  git checkout -f "$target_sha"
  git remote set-url origin "$repo_https"
fi

if ! git config --global --get-all safe.directory | grep -Fxq "$workspace"; then
  git config --global --add safe.directory "$workspace"
fi

if [ "$sync_lfs" = "true" ]; then
  if ! git lfs version >/dev/null 2>&1; then
    echo "::error::Git LFS is required on this runner when sync_lfs=true."
    exit 1
  fi

  git lfs install --skip-repo >/dev/null
  git lfs pull
fi

trap - EXIT
