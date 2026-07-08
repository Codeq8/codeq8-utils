#!/usr/bin/env bash

set -euo pipefail

workspace="${GITHUB_WORKSPACE}"
repo_https="https://github.com/${GITHUB_REPOSITORY}.git"
repo_auth="https://x-access-token:${GITHUB_TOKEN}@github.com/${GITHUB_REPOSITORY}.git"
target_sha="${CODE_BOOTSTRAP_TARGET_SHA:-${GITHUB_SHA}}"
fallback_ref="${CODE_BOOTSTRAP_FALLBACK_REF:-${GITHUB_REF:-}}"
requested_ref="${CODE_BOOTSTRAP_REQUESTED_REF:-}"
requested_sha="${CODE_BOOTSTRAP_REQUESTED_SHA:-}"
sync_lfs="${CODE_BOOTSTRAP_SYNC_LFS:-auto}"

case "$sync_lfs" in
  auto|true|false)
    ;;
  *)
    echo "::error::Invalid sync_lfs value '${sync_lfs}'. Expected auto, true, or false."
    exit 1
    ;;
esac

if [ "$sync_lfs" != "true" ]; then
  export GIT_LFS_SKIP_SMUDGE=1
fi

repo_has_lfs_tracked_files() {
  local tracked_files
  local tracked_attrs
  local found_lfs
  local attr_path
  local attr_name
  local attr_value

  tracked_files="$(mktemp)"
  tracked_attrs="$(mktemp)"
  if ! git ls-files -z > "$tracked_files"; then
    rm -f "$tracked_files" "$tracked_attrs"
    echo "::error::Unable to list tracked files before Git LFS detection."
    exit 1
  fi

  if [ ! -s "$tracked_files" ]; then
    rm -f "$tracked_files" "$tracked_attrs"
    return 1
  fi

  if ! git check-attr -z --stdin filter < "$tracked_files" > "$tracked_attrs"; then
    rm -f "$tracked_files" "$tracked_attrs"
    echo "::error::Unable to inspect tracked file attributes before Git LFS detection."
    exit 1
  fi

  found_lfs="false"
  while IFS= read -r -d '' attr_path &&
    IFS= read -r -d '' attr_name &&
    IFS= read -r -d '' attr_value; do
    if [ "$attr_name" = "filter" ] && [ "$attr_value" = "lfs" ]; then
      found_lfs="true"
      break
    fi
  done < "$tracked_attrs"

  rm -f "$tracked_files" "$tracked_attrs"
  [ "$found_lfs" = "true" ]
}

should_sync_lfs() {
  case "$sync_lfs" in
    true)
      return 0
      ;;
    false)
      return 1
      ;;
  esac

  repo_has_lfs_tracked_files
}

if [ -n "$requested_ref" ]; then
  fallback_ref="$requested_ref"
fi
if [ -n "$requested_sha" ]; then
  target_sha="$requested_sha"
elif [ -n "$requested_ref" ]; then
  target_sha=""
fi

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

    if git cat-file -e "${sha}^{commit}" >/dev/null 2>&1; then
      return 0
    fi

    if git fetch --no-tags origin "$sha"; then
      return 0
    fi

    if [ -n "$next_fallback_ref" ] && git fetch --no-tags origin "$next_fallback_ref"; then
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

fetch_ref_with_lock_recovery() {
  local ref="$1"
  local max_attempts=5
  local attempt=1

  while [ "$attempt" -le "$max_attempts" ]; do
    wait_for_shallow_lock_release || return 1

    if git fetch --no-tags origin "$ref"; then
      return 0
    fi

    if [ "$attempt" -eq "$max_attempts" ]; then
      break
    fi

    echo "::warning::git fetch failed for ${ref} (attempt ${attempt}/${max_attempts}); retrying..."
    sleep 2
    attempt=$((attempt + 1))
  done

  echo "::error::Unable to fetch ${ref} after ${max_attempts} attempts."
  return 1
}

refresh_branch_refs_with_lock_recovery() {
  local max_attempts=5
  local attempt=1
  local branch_refspec="+refs/heads/*:refs/remotes/origin/*"

  while [ "$attempt" -le "$max_attempts" ]; do
    wait_for_shallow_lock_release || return 1

    if [ -f "$workspace/.git/shallow" ]; then
      if git fetch --no-tags --prune --unshallow origin "$branch_refspec"; then
        return 0
      fi
    elif git fetch --no-tags --prune origin "$branch_refspec"; then
      return 0
    fi

    if [ "$attempt" -eq "$max_attempts" ]; then
      break
    fi

    echo "::warning::git branch ref refresh failed (attempt ${attempt}/${max_attempts}); retrying..."
    sleep 2
    attempt=$((attempt + 1))
  done

  echo "::error::Unable to refresh origin branch refs after ${max_attempts} attempts."
  return 1
}

if [ -d "$workspace/.git" ]; then
  cd "$workspace"
  git remote set-url origin "$repo_auth"
  refresh_branch_refs_with_lock_recovery
  if [ -n "$target_sha" ]; then
    fetch_sha_with_lock_recovery "$target_sha" "$fallback_ref"
    git checkout -f "$target_sha"
  else
    fetch_ref_with_lock_recovery "$fallback_ref"
    git checkout -f FETCH_HEAD
  fi
  git remote set-url origin "$repo_https"
else
  if [ -d "$workspace" ] && [ -n "$(ls -A "$workspace" 2>/dev/null)" ]; then
    echo "::error::Expected empty workspace before initial clone."
    ls -la "$workspace"
    exit 1
  fi

  mkdir -p "$workspace"
  git clone --no-tags "$repo_auth" "$workspace"
  cd "$workspace"
  refresh_branch_refs_with_lock_recovery
  if [ -n "$target_sha" ]; then
    fetch_sha_with_lock_recovery "$target_sha" "$fallback_ref"
    git checkout -f "$target_sha"
  else
    fetch_ref_with_lock_recovery "$fallback_ref"
    git checkout -f FETCH_HEAD
  fi
  git remote set-url origin "$repo_https"
fi

if ! git config --global --get-all safe.directory | grep -Fxq "$workspace"; then
  git config --global --add safe.directory "$workspace"
fi

if should_sync_lfs; then
  if ! git lfs version >/dev/null 2>&1; then
    echo "::error::Git LFS is required on this runner when sync_lfs=${sync_lfs} and the repository has tracked LFS files."
    exit 1
  fi

  unset GIT_LFS_SKIP_SMUDGE
  git lfs install --skip-repo >/dev/null
  git lfs pull
fi

trap - EXIT
