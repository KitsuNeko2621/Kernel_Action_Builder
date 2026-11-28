#!/usr/bin/env bash
set -e
source "$(dirname "$0")/common.sh"

KERNEL_REPO_INPUT="${INPUT_KERNEL_REPO}"
PRIVATE_TOKEN="${INPUT_PRIVATE_TOKEN:-}"

[ -n "${PRIVATE_TOKEN}" ] && echo "::add-mask::${PRIVATE_TOKEN}"

# Token: GitHub uses x-access-token, GitLab (and others) use oauth2
if [ -n "${PRIVATE_TOKEN}" ]; then
  if echo "${KERNEL_REPO_INPUT}" | grep -q "github.com"; then
    AUTHED_URL="${KERNEL_REPO_INPUT/https:\/\//https://x-access-token:${PRIVATE_TOKEN}@}"
  else
    AUTHED_URL="${KERNEL_REPO_INPUT/https:\/\//https://oauth2:${PRIVATE_TOKEN}@}"
  fi
else
  AUTHED_URL="${KERNEL_REPO_INPUT}"
fi

# Empty branch = the repository's default branch
BRANCH_OPT=()
[ -n "${INPUT_KERNEL_BRANCH:-}" ] && BRANCH_OPT=(-b "${INPUT_KERNEL_BRANCH}")

git clone --depth=1 "${BRANCH_OPT[@]}" "${AUTHED_URL}" kernel || {
  log_error "Failed to clone kernel source (check URL / branch / token)."
  exit 1
}
cd kernel

# Never keep the token in .git/config
git remote set-url origin "${KERNEL_REPO_INPUT}" 2>/dev/null || true

REPO_BASE=$(echo "${KERNEL_REPO_INPUT}" | sed 's|\.git$||')
FULL_COMMIT=$(git rev-parse HEAD)
BRANCH_NAME="${INPUT_KERNEL_BRANCH:-$(git rev-parse --abbrev-ref HEAD 2>/dev/null || echo default)}"
if echo "${REPO_BASE}" | grep -q "gitlab"; then
  COMMIT_URL="${REPO_BASE}/-/commit/${FULL_COMMIT}"
else
  COMMIT_URL="${REPO_BASE}/commit/${FULL_COMMIT}"
fi

{
  echo "KERNEL_REPO=${KERNEL_REPO_INPUT}"
  echo "KERNEL_DIR=$(pwd)"
  echo "KERNEL_BRANCH=${BRANCH_NAME}"
  echo "KERNEL_COMMIT=${FULL_COMMIT:0:8}"
  echo "KERNEL_COMMIT_URL=${COMMIT_URL}"
  echo "DEFCONFIG=${INPUT_DEFCONFIG:-}"
  echo "CONFIG_FRAGMENTS=${INPUT_FRAGMENTS:-}"
} >> "$GITHUB_ENV"

echo "KERNEL_VERSION=$(make kernelversion 2>/dev/null || echo 'unknown')" >> "$GITHUB_ENV"
echo "KERNEL_COMMIT_MSG=$(git log -1 --pretty=format:'%s')" >> "$GITHUB_ENV"
