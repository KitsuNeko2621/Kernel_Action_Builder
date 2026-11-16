#!/usr/bin/env bash
# Di-source oleh build_kernel.sh SETELAH defconfig dibuat (butuh MAKE_ARGS, KERNEL_DIR, BUILD_LOG).
# Mengubah out/.config saja; file defconfig di source tidak disentuh.

_cfg="${KERNEL_DIR}/out/.config"
_sc="${KERNEL_DIR}/scripts/config"
_tlog()  { echo "[CONFIG] $*"; echo "[CONFIG] $*" >> "${BUILD_LOG}"; }
_twarn() { echo "::warning::$*"; echo "[WARN] $*" >> "${BUILD_LOG}"; }

apply_kernel_config_tweaks() {
  # --- localversion (uname -r) ---------------------------------------------
  if [ -n "${KERNEL_LOCALVERSION:-}" ]; then
    for f in "${KERNEL_DIR}"/localversion*; do
      [ -f "${f}" ] || continue
      _tlog "Hapus $(basename "${f}") ($(cat "${f}"))"
      rm -f "${f}"
    done
    _tlog "LOCALVERSION = \"${KERNEL_LOCALVERSION}\""
    bash "${_sc}" --file "${_cfg}" --set-str LOCALVERSION "${KERNEL_LOCALVERSION}"
    bash "${_sc}" --file "${_cfg}" -d LOCALVERSION_AUTO
    : > "${KERNEL_DIR}/.scmversion"   # cegah tambahan "+" / -dirty / -g<hash>
  fi

  # --- mode hemat RAM -------------------------------------------------------
  if [ "${LOWRAM:-0}" = "1" ]; then
    local cur_shift
    cur_shift=$(sed -n 's/^CONFIG_LOG_BUF_SHIFT=//p' "${_cfg}")
    if [ "${LOWRAM_AGGRESSIVE:-0}" = "1" ]; then
      _tlog "Hemat RAM (agresif): DEBUG_INFO/SCHEDSTATS/KPROBES off, log buffer maks 128 KB"
      bash "${_sc}" --file "${_cfg}" -d DEBUG_INFO -d SCHEDSTATS -d KPROBES
    else
      _tlog "Hemat RAM: DEBUG_INFO off, log buffer maks 128 KB"
      bash "${_sc}" --file "${_cfg}" -d DEBUG_INFO
    fi
    if [ -z "${cur_shift}" ] || [ "${cur_shift}" -gt 17 ]; then
      bash "${_sc}" --file "${_cfg}" --set-val LOG_BUF_SHIFT 17
    fi

    if [ "${ZRAM_COMP_MODE:-none}" = "kconfig" ]; then
      case "${ZRAM_COMP}" in
        lzo)   bash "${_sc}" --file "${_cfg}" -e ZRAM_DEF_COMP_LZO ;;
        lz4)   bash "${_sc}" --file "${_cfg}" -e ZRAM_DEF_COMP_LZ4 ;;
        lz4hc) bash "${_sc}" --file "${_cfg}" -e ZRAM_DEF_COMP_LZ4HC ;;
        zstd)  bash "${_sc}" --file "${_cfg}" -e ZRAM_DEF_COMP_ZSTD ;;
      esac
    fi
    # algoritma crypto-nya harus ikut dikompilasi
    case "${ZRAM_COMP}" in
      lz4)   bash "${_sc}" --file "${_cfg}" -e CRYPTO_LZ4 ;;
      lz4hc) bash "${_sc}" --file "${_cfg}" -e CRYPTO_LZ4HC ;;
      zstd)  bash "${_sc}" --file "${_cfg}" -e CRYPTO_ZSTD ;;
    esac
  fi

  # --- NoMount ---------------------------------------------------------------
  if [ "${INPUT_ENABLE_NOMOUNT:-false}" = "true" ] && [ -e "${KERNEL_DIR}/fs/nomount" ]; then
    bash "${_sc}" --file "${_cfg}" -e NOMOUNT
  fi

  make "${MAKE_ARGS[@]}" olddefconfig 2>&1 | tee -a "${BUILD_LOG}"

  # --- verifikasi hasil ------------------------------------------------------
  if [ "${LOWRAM:-0}" = "1" ]; then
    local opts="DEBUG_INFO"; [ "${LOWRAM_AGGRESSIVE:-0}" = "1" ] && opts="DEBUG_INFO SCHEDSTATS KPROBES"
    for opt in ${opts}; do
      grep -q "^CONFIG_${opt}=y" "${_cfg}" && _twarn "CONFIG_${opt} tetap aktif (dipaksa opsi lain)."
    done
    if [ "${ZRAM_COMP_MODE:-none}" = "kconfig" ] && ! grep -q "^CONFIG_ZRAM_DEF_COMP=\"${ZRAM_COMP}\"" "${_cfg}"; then
      _twarn "Kompresor zram di .config bukan '${ZRAM_COMP}': $(grep '^CONFIG_ZRAM_DEF_COMP=' "${_cfg}" || echo 'n/a')"
    fi
    case "${ZRAM_COMP}" in
      lz4)   grep -q '^CONFIG_CRYPTO_LZ4=y' "${_cfg}"   || _twarn "CONFIG_CRYPTO_LZ4 tidak =y, zram lz4 bisa gagal init." ;;
      lz4hc) grep -q '^CONFIG_CRYPTO_LZ4HC=y' "${_cfg}" || _twarn "CONFIG_CRYPTO_LZ4HC tidak =y, zram lz4hc bisa gagal init." ;;
      zstd)  grep -q '^CONFIG_CRYPTO_ZSTD=y' "${_cfg}"  || _twarn "CONFIG_CRYPTO_ZSTD tidak =y, zram zstd bisa gagal init." ;;
    esac
  fi
  if [ "${INPUT_ENABLE_NOMOUNT:-false}" = "true" ] && [ -e "${KERNEL_DIR}/fs/nomount" ]; then
    grep -q '^CONFIG_NOMOUNT=y' "${_cfg}" && _tlog "CONFIG_NOMOUNT=y" || _twarn "CONFIG_NOMOUNT tidak aktif di .config."
    grep -q '^CONFIG_KEYS=y' "${_cfg}" || _twarn "CONFIG_KEYS tidak aktif: NoMount berkomunikasi lewat keyring."
  fi
}
