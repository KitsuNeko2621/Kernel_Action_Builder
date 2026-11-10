#!/usr/bin/env bash
set -eo pipefail
cd "${KERNEL_DIR}"

start_time=$(date +%s)

export PATH="${CLANG_PATH}:${PATH}"
export KBUILD_BUILD_USER="elohim-etz"
export KBUILD_BUILD_HOST="GitHub-Actions"

echo "=== Toolchain ==="
echo "Type: ${CLANG_TOOLCHAIN}"
echo "Path: ${CLANG_PATH}"
"${CLANG_PATH}/clang" --version | head -n 1

# Flag make yang sama dipakai di SEMUA langkah (defconfig, header, build)
MAKE_ARGS=(
  O=out
  ARCH="${ARCH}"
  SUBARCH="${ARCH}"
  CC="ccache clang"
  LLVM=1
  CROSS_COMPILE=aarch64-linux-gnu-
  CROSS_COMPILE_ARM32=arm-linux-gnueabi-
  CLANG_TRIPLE=aarch64-linux-gnu-
  CONFIG_NO_ERROR_ON_MISMATCH=y
)

rm -rf out
mkdir -p out

echo "=== Generating defconfig: ${DEFCONFIG} ===" | tee -a "$BUILD_LOG"
make "${MAKE_ARGS[@]}" "${DEFCONFIG}" 2>&1 | tee -a "$BUILD_LOG"

# Generate header arch/uapi secara serial supaya tidak race dengan compile paralel
echo "=== Generating headers (serial) ===" | tee -a "$BUILD_LOG"
make "${MAKE_ARGS[@]}" -j1 archheaders 2>&1 | tee -a "$BUILD_LOG"
make "${MAKE_ARGS[@]}" -j1 prepare     2>&1 | tee -a "$BUILD_LOG"

echo "=== Starting kernel build ===" | tee -a "$BUILD_LOG"
make -j"$(nproc --all)" "${MAKE_ARGS[@]}" 2>&1 | tee -a "$BUILD_LOG"

grep -i -E "error:|undefined reference|fatal error" \
  "$BUILD_LOG" > "$ERROR_LOG" || true

BUILD_DURATION=$(( $(date +%s) - start_time ))
echo "BUILD_DURATION=${BUILD_DURATION}" >> "$GITHUB_ENV"

ccache --show-stats | tee -a "$BUILD_LOG"
