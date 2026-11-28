#!/usr/bin/env bash
set -eo pipefail
cd "${KERNEL_DIR}"

start_time=$(date +%s)

export PATH="${CLANG_PATH}:${PATH}"
export KBUILD_BUILD_USER="KitsuNeko"
export KBUILD_BUILD_HOST="GitHub-Actions"

echo "=== Toolchain ==="
echo "Type: ${CLANG_TOOLCHAIN}"
echo "Path: ${CLANG_PATH}"
"${CLANG_PATH}/clang" --version | head -n 1

mkdir -p out

echo "=== Generating defconfig: ${DEFCONFIG} ===" | tee -a "$BUILD_LOG"
make O=out \
     ARCH="${ARCH}" \
     "${DEFCONFIG}" \
     2>&1 | tee -a "$BUILD_LOG"

FRAGMENTS="${CONFIG_FRAGMENTS}"
if [ "${ENABLE_KSU}" == "true" ]; then
  if [ -n "${FRAGMENTS}" ]; then
    FRAGMENTS="${FRAGMENTS} ksu.config"
  else
    FRAGMENTS="ksu.config"
  fi
fi

if [ -n "${FRAGMENTS}" ]; then
  echo "=== Merging config fragments: ${FRAGMENTS} ===" | tee -a "$BUILD_LOG"

  read -r -a FRAGMENT_LIST <<< "${FRAGMENTS}"
  MERGE_FILES=("out/.config")

  for frag in "${FRAGMENT_LIST[@]}"; do
    if [ -f "${frag}" ]; then
      frag_path="${frag}"
    elif [ -f "arch/${ARCH}/configs/${frag}" ]; then
      frag_path="arch/${ARCH}/configs/${frag}"
    else
      echo "ERROR: config fragment '${frag}' not found in ./ or arch/${ARCH}/configs/" | tee -a "$BUILD_LOG"
      exit 1
    fi
    echo "  + ${frag_path}" | tee -a "$BUILD_LOG"
    MERGE_FILES+=("${frag_path}")
  done

  if [ -f scripts/kconfig/merge_config.sh ]; then
    bash scripts/kconfig/merge_config.sh -m -O out "${MERGE_FILES[@]}" 2>&1 | tee -a "$BUILD_LOG"
  else
    # Fallback: plain concatenation (later entries win after olddefconfig)
    cat "${MERGE_FILES[@]}" > out/.config.tmp
    mv out/.config.tmp out/.config
  fi

  make O=out ARCH="${ARCH}" olddefconfig 2>&1 | tee -a "$BUILD_LOG"
fi

echo "=== Starting kernel build ===" | tee -a "$BUILD_LOG"
make -j"$(nproc --all)" \
     O=out \
     ARCH="${ARCH}" \
     CC="ccache clang" \
     LLVM=1 \
     CONFIG_NO_ERROR_ON_MISMATCH=y \
     2>&1 | tee -a "$BUILD_LOG"

grep -i -E "error:|undefined reference|fatal error" \
  "$BUILD_LOG" > "$ERROR_LOG" || true

BUILD_DURATION=$(( $(date +%s) - start_time ))
echo "BUILD_DURATION=${BUILD_DURATION}" >> "$GITHUB_ENV"

ccache --show-stats | tee -a "$BUILD_LOG"
