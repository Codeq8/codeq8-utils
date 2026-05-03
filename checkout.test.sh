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

printf '%s|%s\n' "${1:-}" "${GIT_LFS_SKIP_SMUDGE-<unset>}" >> "$CODEQ8_TEST_GIT_LOG"

case "${1:-}" in
  -C)
    exit 0
    ;;
  clone)
    mkdir -p "${3:?}/.git"
    exit 0
    ;;
  config|fetch|checkout|remote)
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

  rm -rf "$workspace"
  : > "$git_log"

  env -u GIT_LFS_SKIP_SMUDGE \
    PATH="$fake_bin:$PATH" \
    CODEQ8_TEST_GIT_LOG="$git_log" \
    GITHUB_WORKSPACE="$workspace" \
    GITHUB_REPOSITORY="acme/widgets" \
    GITHUB_TOKEN="token" \
    GITHUB_SHA="target-sha" \
    GITHUB_REF="refs/heads/main" \
    CODE_BOOTSTRAP_SYNC_LFS="$sync_lfs" \
    bash "$repo_root/checkout.sh"
}

run_checkout "false"
grep -Fxq "clone|1" "$git_log"
grep -Fxq "fetch|1" "$git_log"
grep -Fxq "checkout|1" "$git_log"

run_checkout "true"
grep -Fxq "clone|<unset>" "$git_log"
grep -Fxq "fetch|<unset>" "$git_log"
grep -Fxq "checkout|<unset>" "$git_log"
