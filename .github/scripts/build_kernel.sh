#!/usr/bin/env bash
set -eo pipefail
source "$(dirname "$0")/common.sh"
cd "${KERNEL_DIR}"

start_time=$(date +%s)
OUT_DIR="${KERNEL_DIR}/out"
SC="${KERNEL_DIR}/scripts/config"
JOBS=$(nproc --all)

export PATH="${CLANG_PATH}:${PATH}"
export ARCH="${ARCH:-arm64}"
export KBUILD_BUILD_USER="${KBUILD_BUILD_USER:-elohim-etz}"
export KBUILD_BUILD_HOST="${KBUILD_BUILD_HOST:-GitHub-Actions}"

# Always extract the error lines, even when the build dies half-way
extract_errors() {
  grep -i -E "error:|undefined reference|fatal error|\[ERROR\]" "${BUILD_LOG}" > "${ERROR_LOG}" 2>/dev/null || true
}
trap extract_errors EXIT

echo "=== Toolchain ==="
echo "Type: ${CLANG_TOOLCHAIN}${CLANG_TAG:+ (tag ${CLANG_TAG})}"
echo "Path: ${CLANG_PATH}"
"${CLANG_PATH}/clang" --version | head -n 1

mkdir -p "${OUT_DIR}"

CC_CMD="clang"
command -v ccache &>/dev/null && CC_CMD="ccache clang"
MAKE_ARGS=(
  -j"${JOBS}"
  O="${OUT_DIR}"
  ARCH="${ARCH}"
  CC="${CC_CMD}"
  LLVM=1
  LLVM_IAS=1
  LD=ld.lld
  AR=llvm-ar
  NM=llvm-nm
  OBJCOPY=llvm-objcopy
  OBJDUMP=llvm-objdump
  READELF=llvm-readelf
  STRIP=llvm-strip
  CROSS_COMPILE=aarch64-linux-gnu-
  CROSS_COMPILE_ARM32=arm-linux-gnueabi-
  CROSS_COMPILE_COMPAT=arm-linux-gnueabi-
  CLANG_TRIPLE=aarch64-linux-gnu-
  CONFIG_NO_ERROR_ON_MISMATCH=y
)

# ── defconfig (auto-detect when left empty) ─────────────────────────────────
detect_defconfig() {
  local cfg="${KERNEL_DIR}/arch/${ARCH}/configs"
  if   [ -f "${cfg}/k85v1_64_k419_defconfig" ] && [ -f "${cfg}/vendor/nemo.config" ]; then
    DEFCONFIG="k85v1_64_k419_defconfig vendor/nemo.config"
  elif [ -f "${cfg}/RM6785_defconfig" ]; then DEFCONFIG="RM6785_defconfig"
  elif [ -f "${cfg}/nemo_defconfig" ];   then DEFCONFIG="nemo_defconfig"
  elif [ -f "${cfg}/gki_defconfig" ] && [ -f "${cfg}/vendor/nemo.config" ]; then
    DEFCONFIG="gki_defconfig vendor/nemo.config"
  else
    log_error "defconfig is empty and none could be auto-detected. Similar files:"
    (cd "${cfg}" && ls -d *6785* *nemo* vendor/*nemo* 2>/dev/null | sed 's/^/    /') || true
    exit 1
  fi
  log_info "defconfig auto-detected: ${DEFCONFIG}"
}
[ -n "${DEFCONFIG}" ] || detect_defconfig
read -r -a DEFCONFIG_LIST <<< "${DEFCONFIG}"

echo "=== Generating defconfig: ${DEFCONFIG} ===" | tee -a "$BUILD_LOG"
make "${MAKE_ARGS[@]}" "${DEFCONFIG_LIST[@]}" 2>&1 | tee -a "$BUILD_LOG"

# ── config fragments (ksu.config is appended when KernelSU is enabled) ──
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
  MERGE_FILES=("${OUT_DIR}/.config")

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
    bash scripts/kconfig/merge_config.sh -m -O "${OUT_DIR}" "${MERGE_FILES[@]}" 2>&1 | tee -a "$BUILD_LOG"
  else
    # Fallback: plain concatenation (later entries win after olddefconfig)
    cat "${MERGE_FILES[@]}" > "${OUT_DIR}/.config.tmp"
    mv "${OUT_DIR}/.config.tmp" "${OUT_DIR}/.config"
  fi

  make "${MAKE_ARGS[@]}" olddefconfig 2>&1 | tee -a "$BUILD_LOG"
fi

olddefconfig() {
  make "${MAKE_ARGS[@]}" olddefconfig >> "${BUILD_LOG}" 2>&1 || { log_error "olddefconfig failed."; exit 1; }
}

# ── a merged config missing the platform symbol fails hours later; stop now ──
# EXPECT_MTK_PLATFORM=""  -> skip the check (non-MediaTek kernels)
verify_config() {
  local c="${OUT_DIR}/.config" bad=0 want="${EXPECT_MTK_PLATFORM-mt6785}"
  if [ -n "${want}" ]; then
    grep -q "^CONFIG_MTK_PLATFORM=\"${want}\"" "$c" || {
      log_error "CONFIG_MTK_PLATFORM is not \"${want}\" -> incomplete configuration."; bad=1; }
    grep -q '^CONFIG_BUILD_ARM64_APPENDED_DTB_IMAGE=y' "$c" || \
      log_warn "APPENDED_DTB_IMAGE is off; the output may not be Image.gz-dtb."
    grep -q "mediatek/${want}" "$c" || log_warn "DTB ${want} is not listed in .config."
  fi
  if [ "${bad}" -eq 1 ]; then
    echo "  Configs used: ${DEFCONFIG} ${CONFIG_FRAGMENTS}" | tee -a "${BUILD_LOG}"
    echo "  Check defconfig / fragments in the kernel repo (README, build.config*, arch/arm64/configs/)." | tee -a "${BUILD_LOG}"
    [ "${ALLOW_BAD_CONFIG:-0}" = "1" ] || exit 1
  fi
}

# ── LOCALVERSION (uname -r). Empty input = leave the kernel's own string ────
apply_localversion() {
  [ -n "${LOCALVERSION_SUFFIX:-}" ] || return 0
  if [ "${REMOVE_LOCALVERSION_FILES:-1}" = "1" ]; then
    local f
    for f in "${KERNEL_DIR}"/localversion*; do
      [ -f "${f}" ] || continue
      log_info "Removing $(basename "${f}") ($(cat "${f}"))"
      rm -f "${f}"
    done
  fi
  log_info "LOCALVERSION = \"${LOCALVERSION_SUFFIX}\""
  bash "${SC}" --file "${OUT_DIR}/.config" --set-str LOCALVERSION "${LOCALVERSION_SUFFIX}"
  if [ "${DISABLE_LOCALVERSION_AUTO:-1}" = "1" ]; then
    bash "${SC}" --file "${OUT_DIR}/.config" -d LOCALVERSION_AUTO
    : > "${KERNEL_DIR}/.scmversion"   # empty -> no "+" / -dirty / -g<hash> suffix
  fi
  olddefconfig
}

# ── low-RAM mode (applied to out/.config, defconfig files untouched) ────────
apply_lowram_config() {
  [ "${LOWRAM:-0}" = "1" ] || return 0
  local cfg="${OUT_DIR}/.config" cur_shift sym opt opts="DEBUG_INFO"
  cur_shift=$(sed -n 's/^CONFIG_LOG_BUF_SHIFT=//p' "${cfg}")
  if [ "${LOWRAM_AGGRESSIVE:-0}" = "1" ]; then
    log_info "Low-RAM mode (aggressive): DEBUG_INFO/SCHEDSTATS/KPROBES off, log buffer max 128 KB"
    bash "${SC}" --file "${cfg}" -d DEBUG_INFO -d SCHEDSTATS -d KPROBES
    opts="DEBUG_INFO SCHEDSTATS KPROBES"
  else
    log_info "Low-RAM mode: only DEBUG_INFO off (SCHEDSTATS/KPROBES untouched), log buffer max 128 KB"
    bash "${SC}" --file "${cfg}" -d DEBUG_INFO
  fi
  # the log buffer is only ever shrunk
  if [ -z "${cur_shift}" ] || [ "${cur_shift}" -gt 17 ]; then
    bash "${SC}" --file "${cfg}" --set-val LOG_BUF_SHIFT 17
  fi
  # zram compressor via Kconfig (4.14) + make sure the crypto algorithm is built in
  if [ "${ZRAM_COMP_MODE:-}" = "kconfig" ]; then
    case "${ZRAM_COMP}" in
      lzo-rle) sym=ZRAM_DEF_COMP_LZORLE ;;
      lzo)     sym=ZRAM_DEF_COMP_LZO ;;
      lz4)     sym=ZRAM_DEF_COMP_LZ4 ;;
      lz4hc)   sym=ZRAM_DEF_COMP_LZ4HC ;;
      zstd)    sym=ZRAM_DEF_COMP_ZSTD ;;
    esac
    bash "${SC}" --file "${cfg}" -e "${sym}"
  fi
  case "${ZRAM_COMP}" in
    lz4)   bash "${SC}" --file "${cfg}" -e CRYPTO_LZ4 ;;
    lz4hc) bash "${SC}" --file "${cfg}" -e CRYPTO_LZ4HC ;;
    zstd)  bash "${SC}" --file "${cfg}" -e CRYPTO_ZSTD ;;
  esac
  olddefconfig
  for opt in ${opts}; do
    grep -q "^CONFIG_${opt}=y" "${cfg}" && log_warn "CONFIG_${opt} is still on (forced by another option)."
  done
  if [ "${ZRAM_COMP_MODE:-}" = "kconfig" ] && ! grep -q "^CONFIG_ZRAM_DEF_COMP=\"${ZRAM_COMP}\"" "${cfg}"; then
    log_warn "zram compressor in .config is not '${ZRAM_COMP}': $(grep '^CONFIG_ZRAM_DEF_COMP=' "${cfg}")"
  fi
}

# ── NoMount ─────────────────────────────────────────────────────────────────
apply_nomount_config() {
  [ -e "${KERNEL_DIR}/fs/nomount" ] || return 0
  bash "${SC}" --file "${OUT_DIR}/.config" -e NOMOUNT
  olddefconfig
  grep -q '^CONFIG_NOMOUNT=y' "${OUT_DIR}/.config" && log_info "CONFIG_NOMOUNT=y" || log_warn "CONFIG_NOMOUNT is not enabled in .config."
  grep -q '^CONFIG_KEYS=y' "${OUT_DIR}/.config" || log_warn "CONFIG_KEYS is off: NoMount talks through the keyring and will not work."
}

# ── 32-bit vDSO needs a clang with an ARM target; some builds ship AArch64/x86 only ──
fix_compat_vdso() {
  local mode="${DISABLE_COMPAT_VDSO:-auto}"
  grep -q '^CONFIG_COMPAT_VDSO=y' "${OUT_DIR}/.config" || return 0
  [ "${mode}" = "0" ] && return 0
  if [ "${mode}" = "auto" ] && \
     "${CLANG_PATH}/clang" --print-targets 2>/dev/null | grep -qE '^[[:space:]]+arm[[:space:]]'; then
    return 0
  fi
  log_warn "This clang has no 32-bit ARM target -> CONFIG_COMPAT_VDSO disabled (32-bit apps still work; time calls go through syscalls)."
  bash "${SC}" --file "${OUT_DIR}/.config" -d COMPAT_VDSO
  olddefconfig
}

verify_config
apply_localversion
apply_lowram_config
apply_nomount_config
fix_compat_vdso

# arch/uapi headers first and serial, so they cannot race the parallel build
log_info "Preparing arch headers (serial)..."
make "${MAKE_ARGS[@]}" -j1 archheaders 2>&1 | tee -a "$BUILD_LOG"

echo "=== Starting kernel build (${JOBS} jobs) ===" | tee -a "$BUILD_LOG"
make "${MAKE_ARGS[@]}" 2>&1 | tee -a "$BUILD_LOG"

[ -f "${OUT_DIR}/include/config/kernel.release" ] && \
  log_info "Kernel version (uname -r): $(cat "${OUT_DIR}/include/config/kernel.release")"

BUILD_DURATION=$(( $(date +%s) - start_time ))
echo "BUILD_DURATION=${BUILD_DURATION}" >> "$GITHUB_ENV"

ccache --show-stats | tee -a "$BUILD_LOG"
