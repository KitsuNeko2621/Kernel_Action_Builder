#!/usr/bin/env bash
# Validates workflow inputs and resolves the *effective* options used by the
# later steps. Everything is exported to $GITHUB_ENV.
#
# stable_mode = conservative comparison build (handy when hunting a bootloop):
# it switches off KernelSU/SUSFS, NoMount, low-RAM mode, swappiness and VM/zram patches.
set -euo pipefail
source "$(dirname "$0")/common.sh"

# trim leading/trailing whitespace (inputs typed by hand often carry stray spaces)
trim() { local v="${1:-}"; v="${v#"${v%%[![:space:]]*}"}"; v="${v%"${v##*[![:space:]]}"}"; printf '%s' "$v"; }
b() { [ "$(trim "${1:-}")" = "true" ] && echo 1 || echo 0; }   # "true" -> 1, anything else -> 0

STABLE=$(b "${INPUT_STABLE_MODE:-false}")
ENABLE_KSU=$(trim "${INPUT_ENABLE_KSU:-false}")
NOMOUNT=$(b "${INPUT_ENABLE_NOMOUNT:-false}")
VM_TUNE=$(b "${INPUT_VM_TUNE:-false}")
SWAPPINESS_LOCK=$(b "${INPUT_SWAPPINESS_LOCK:-false}")
SWAPPINESS_DEFAULT=$(trim "${INPUT_SWAPPINESS_DEFAULT:-off}")
LOWRAM_MODE=$(trim "${INPUT_LOWRAM_MODE:-off}")
LOWRAM_AGGRESSIVE=$(b "${INPUT_AGGRESSIVE_DEBUG_OFF:-false}")
ZRAM_MIN_PERCENT=$(trim "${INPUT_ZRAM_SIZE_PERCENT:-0}")
ZRAM_MIN_PERCENT="${ZRAM_MIN_PERCENT%\%}"          # accept "100%"
[ -n "${ZRAM_MIN_PERCENT}" ] || ZRAM_MIN_PERCENT=0   # empty = unchanged
LOCALVERSION_SUFFIX=$(trim "${INPUT_LOCALVERSION:-}")

# ── swappiness: "off" disables the patch ───────────────────────────────────
if [ "${SWAPPINESS_DEFAULT}" = "off" ] || [ -z "${SWAPPINESS_DEFAULT}" ]; then
  SWAPPINESS_PATCH=0; SWAPPINESS_DEFAULT=100
else
  SWAPPINESS_PATCH=1
  if ! [[ "${SWAPPINESS_DEFAULT}" =~ ^[0-9]+$ ]] || [ "${SWAPPINESS_DEFAULT}" -gt 200 ]; then
    log_error "swappiness_default must be a number 0-200 or 'off' (got '${SWAPPINESS_DEFAULT}')"; exit 1
  fi
fi

# ── zram size: 0 = unchanged ───────────────────────────────────────────────
if ! [[ "${ZRAM_MIN_PERCENT}" =~ ^[0-9]+$ ]] || [ "${ZRAM_MIN_PERCENT}" -gt 200 ]; then
  log_error "zram_size_percent must be a number 0-200 (got '${ZRAM_MIN_PERCENT}')"; exit 1
fi

# ── low-RAM mode + zram compressor ─────────────────────────────────────────
if [ "${LOWRAM_MODE}" = "off" ]; then LOWRAM=0; ZRAM_COMP="lz4"; else LOWRAM=1; ZRAM_COMP="${LOWRAM_MODE}"; fi

# ── localversion: empty = leave the kernel's own version string alone ──────
if [[ "${LOCALVERSION_SUFFIX}" =~ [[:space:]] ]] || [ "${#LOCALVERSION_SUFFIX}" -gt 64 ]; then
  log_error "localversion must not contain spaces and is limited to 64 characters: '${LOCALVERSION_SUFFIX}'"; exit 1
fi

# ── stable mode overrides everything above ─────────────────────────────────
if [ "${STABLE}" = "1" ]; then
  ENABLE_KSU="false"; NOMOUNT=0; VM_TUNE=0
  SWAPPINESS_PATCH=0; LOWRAM=0; ZRAM_MIN_PERCENT=0
  log_info "stable_mode ON: KernelSU/SUSFS, NoMount, low-RAM, swappiness and VM/zram patches are disabled."
fi

# ── toolchain ──────────────────────────────────────────────────────────────
CLANG_TYPE=$(echo "${INPUT_CLANG_TOOLCHAIN:-AOSP}" | tr '[:upper:]' '[:lower:]')
case "${CLANG_TYPE}" in aosp|neutron|greenforce|weebx|zyc) ;; *)
  log_error "Unknown clang_toolchain: ${INPUT_CLANG_TOOLCHAIN}"; exit 1 ;; esac

{
  echo "STABLE=${STABLE}"
  echo "ENABLE_KSU=${ENABLE_KSU}"
  echo "NOMOUNT=${NOMOUNT}"
  echo "NOMOUNT_REF=${INPUT_NOMOUNT_REF:-dev}"
  echo "VM_TUNE=${VM_TUNE}"
  echo "SWAPPINESS_PATCH=${SWAPPINESS_PATCH}"
  echo "SWAPPINESS_DEFAULT=${SWAPPINESS_DEFAULT}"
  echo "SWAPPINESS_LOCK=${SWAPPINESS_LOCK}"
  echo "LOWRAM=${LOWRAM}"
  echo "LOWRAM_AGGRESSIVE=${LOWRAM_AGGRESSIVE}"
  echo "ZRAM_COMP=${ZRAM_COMP}"
  echo "ZRAM_MIN_PERCENT=${ZRAM_MIN_PERCENT}"
  echo "LOCALVERSION_SUFFIX=${LOCALVERSION_SUFFIX}"
  echo "CLANG_TYPE=${CLANG_TYPE}"
  echo "GF_CLANG_VERSION=${INPUT_CLANG_VERSION:-latest}"
} >> "${GITHUB_ENV}"

log_info "Resolved: ksu=${ENABLE_KSU}/${INPUT_KSU_VARIANT:-}, nomount=${NOMOUNT}, vm_tune=${VM_TUNE}, swappiness=${SWAPPINESS_PATCH}(${SWAPPINESS_DEFAULT}, lock=${SWAPPINESS_LOCK}), lowram=${LOWRAM}(${ZRAM_COMP}), zram_min=${ZRAM_MIN_PERCENT}%, clang=${CLANG_TYPE}"
