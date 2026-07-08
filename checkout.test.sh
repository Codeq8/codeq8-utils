#!/usr/bin/env bash

set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
temp_root="$(mktemp -d)"
trap 'rm -rf "$temp_root"' EXIT

fake_bin="$temp_root/bin"
workspace="$temp_root/workspace"
git_log="$temp_root/git.log"
mkdir -p "$fake_bin"

cat > "$fake_bin/git" <<'EOF'
#!/usr/bin/env bash

set -euo pipefail

printf '%s|%s\n' "$*" "${GIT_LFS_SKIP_SMUDGE-<unset>}" >> "$CODEQ8_TEST_GIT_LOG"

case "${1:-}" in
  -C)
    exit 0
    ;;
  clone)
    destination="${@: -1}"
    mkdir -p "${destination:?}/.git"
    exit 0
    ;;
  cat-file)
    exit 1
    ;;
  config|checkout|remote)
    exit 0
    ;;
  fetch)
    if [[ "$*" == *"--unshallow"* ]]; then
      rm -f "${GITHUB_WORKSPACE:?}/.git/shallow"
    fi
    exit 0
    ;;
  ls-files)
    if [ "${CODEQ8_TEST_LFS_MODE:-none}" = "tracked" ]; then
      printf 'Assets/PlayerController.prefab\0'
    elif [ "${CODEQ8_TEST_LFS_MODE:-none}" = "non-lfs" ]; then
      printf 'src/index.js\0'
    fi
    exit 0
    ;;
  check-attr)
    while IFS= read -r -d '' path; do
      if [ "${CODEQ8_TEST_LFS_MODE:-none}" = "tracked" ]; then
        printf '%s\0filter\0lfs\0' "$path"
      else
        printf '%s\0filter\0unspecified\0' "$path"
      fi
    done
    exit 0
    ;;
  lfs)
    exit 0
    ;;
esac

exit 0
EOF

chmod 700 "$fake_bin/git"

run_checkout() {
  local sync_lfs="$1"
  local workspace_mode="${2:-fresh}"
  local lfs_mode="${3:-none}"

  rm -rf "$workspace"
  : > "$git_log"
  if [ "$workspace_mode" = "existing-shallow" ]; then
    mkdir -p "$workspace/.git"
    : > "$workspace/.git/shallow"
  fi

  env -u GIT_LFS_SKIP_SMUDGE \
    PATH="$fake_bin:$PATH" \
    CODEQ8_TEST_GIT_LOG="$git_log" \
    GITHUB_WORKSPACE="$workspace" \
    GITHUB_REPOSITORY="acme/widgets" \
    GITHUB_TOKEN="token" \
    GITHUB_SHA="target-sha" \
    GITHUB_REF="refs/heads/main" \
    CODEQ8_TEST_LFS_MODE="$lfs_mode" \
    CODE_BOOTSTRAP_SYNC_LFS="$sync_lfs" \
    bash "$repo_root/checkout.sh"
}

branch_refspec="+refs/heads/*:refs/remotes/origin/*"

run_checkout "false" "fresh"
grep -Fxq "clone --no-tags https://x-access-token:token@github.com/acme/widgets.git $workspace|1" "$git_log"
grep -Fxq "fetch --no-tags --prune origin $branch_refspec|1" "$git_log"
grep -Fxq "fetch --no-tags origin target-sha|1" "$git_log"
grep -Fxq "checkout -f target-sha|1" "$git_log"
if grep -F -- "--depth=1" "$git_log"; then
  echo "checkout should not use shallow fetches"
  exit 1
fi

run_checkout "false" "existing-shallow"
grep -Fxq "fetch --no-tags --prune --unshallow origin $branch_refspec|1" "$git_log"
grep -Fxq "fetch --no-tags origin target-sha|1" "$git_log"
grep -Fxq "checkout -f target-sha|1" "$git_log"
if [ -f "$workspace/.git/shallow" ]; then
  echo "checkout should unshallow existing persistent workspaces"
  exit 1
fi

run_checkout "true" "fresh"
grep -Fxq "clone --no-tags https://x-access-token:token@github.com/acme/widgets.git $workspace|<unset>" "$git_log"
grep -Fxq "fetch --no-tags --prune origin $branch_refspec|<unset>" "$git_log"
grep -Fxq "fetch --no-tags origin target-sha|<unset>" "$git_log"
grep -Fxq "checkout -f target-sha|<unset>" "$git_log"
grep -Fxq "lfs pull|<unset>" "$git_log"

run_checkout "auto" "fresh" "non-lfs"
grep -Fxq "clone --no-tags https://x-access-token:token@github.com/acme/widgets.git $workspace|1" "$git_log"
grep -Fxq "ls-files -z|1" "$git_log"
grep -Fxq "check-attr -z --stdin filter|1" "$git_log"
if grep -Fq "lfs " "$git_log"; then
  echo "auto checkout should not require git lfs when no tracked files use LFS"
  exit 1
fi

run_checkout "auto" "fresh" "tracked"
grep -Fxq "clone --no-tags https://x-access-token:token@github.com/acme/widgets.git $workspace|1" "$git_log"
grep -Fxq "ls-files -z|1" "$git_log"
grep -Fxq "check-attr -z --stdin filter|1" "$git_log"
grep -Fxq "lfs version|1" "$git_log"
grep -Fxq "lfs install --skip-repo|<unset>" "$git_log"
grep -Fxq "lfs pull|<unset>" "$git_log"
