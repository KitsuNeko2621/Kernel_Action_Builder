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

# Bersihkan sisa build in-tree / file generated yang ikut ter-commit di repo kernel.
# Folder ini bikin wrapper uapi (asm/types.h) tidak digenerate ke out/ pada build O=out.
rm -rf out \
       "arch/${ARCH}/include/generated" \
       include/generated \
       include/config \
       .config .config.old
mkdir -p out

echo "=== Generating defconfig: ${DEFCONFIG} ===" | tee -a "$BUILD_LOG"
make "${MAKE_ARGS[@]}" "${DEFCONFIG}" 2>&1 | tee -a "$BUILD_LOG"

# Generate header arch/uapi secara serial supaya tidak race dengan compile paralel
echo "=== Generating headers (serial) ===" | tee -a "$BUILD_LOG"
make "${MAKE_ARGS[@]}" -j1 archheaders 2>&1 | tee -a "$BUILD_LOG"

echo "=== DIAG: asm/types.h ===" | tee -a "$BUILD_LOG"
ls -la arch/arm64/include/uapi/asm/types.h arch/arm64/include/asm/types.h 2>&1 | tee -a "$BUILD_LOG" || true
find . -path '*asm/types.h' -not -path './out/*' 2>/dev/null | head -n 20 | tee -a "$BUILD_LOG" || true
find out -path '*asm/types.h' 2>/dev/null | head -n 20 | tee -a "$BUILD_LOG" || true
echo "--- uapi Kbuild / out types.h ---" | tee -a "$BUILD_LOG"
cat arch/arm64/include/uapi/asm/Kbuild 2>&1 | tee -a "$BUILD_LOG" || true
ls -la out/arch/arm64/include/generated/uapi/asm/ 2>&1 | head -n 20 | tee -a "$BUILD_LOG" || true
echo "--- git status (kernel) ---" | tee -a "$BUILD_LOG"
git status --short 2>/dev/null | head -n 40 | tee -a "$BUILD_LOG" || true
git log --oneline -n 3 2>/dev/null | tee -a "$BUILD_LOG" || true

# V=1 supaya perintah clang lengkap (termasuk semua -I dan --target) tercatat di log
make "${MAKE_ARGS[@]}" -j1 V=1 prepare 2>&1 | tee -a "$BUILD_LOG"

echo "=== Starting kernel build ===" | tee -a "$BUILD_LOG"
make -j"$(nproc --all)" "${MAKE_ARGS[@]}" 2>&1 | tee -a "$BUILD_LOG"

grep -i -E "error:|undefined reference|fatal error" \
  "$BUILD_LOG" > "$ERROR_LOG" || true

BUILD_DURATION=$(( $(date +%s) - start_time ))
echo "BUILD_DURATION=${BUILD_DURATION}" >> "$GITHUB_ENV"

ccache --show-stats | tee -a "$BUILD_LOG"
