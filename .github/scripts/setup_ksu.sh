#!/usr/bin/env bash
set -e
cd "${KERNEL_DIR}"

# ── Stock fallback ──────────────────────────────────────────────────────────
if [ "${ENABLE_KSU}" != "true" ]; then
  {
    echo "KSU_VARIANT=Stock"
    echo "SUSFS_ENABLED=false"
    echo "BUILD_VARIANT=Normal"
  } >> "$GITHUB_ENV"
  exit 0
fi

# ── Variants ────────────────────────────────────────────────────────────────
case "${KSU_VARIANT_INPUT}" in
  xxKSU)
    curl -LSs "https://raw.githubusercontent.com/backslashxx/KernelSU/master/kernel/setup.sh" | bash -s master
    KSU_BRANCH="master"; SUSFS="false"
    KSU_REPO="https://github.com/backslashxx/KernelSU"
    if [ "${ENABLE_SUSFS}" == "true" ]; then
      echo "::warning::xxKSU does not support SUSFS — flag ignored."
    fi
    ;;
  SukiSU)
    if [ "${ENABLE_SUSFS}" == "true" ]; then
      curl -LSs "https://raw.githubusercontent.com/SukiSU-Ultra/SukiSU-Ultra/main/kernel/setup.sh" | bash -s main
      KSU_BRANCH="main"; SUSFS="true"
    else
      curl -LSs "https://raw.githubusercontent.com/SukiSU-Ultra/SukiSU-Ultra/main/kernel/setup.sh" | bash -s builtin
      KSU_BRANCH="builtin"; SUSFS="false"
    fi
    KSU_REPO="https://github.com/SukiSU-Ultra/SukiSU-Ultra"
    ;;
  BakaSU)
    # Always track the latest BakaSU main (REF can be overridden with BAKASU_REF,
    # e.g. a branch, tag or commit). The SUSFS build gate added in 48fa4bb7
    # (2026-10-10, "Please wait susfs update.") is gone from main as of d5e9e025
    # (2026-10-25) and the old sync-susfs branch no longer exists, so no special
    # SUSFS handling is needed any more.
    BAKASU_REF="${BAKASU_REF:-main}"
    curl -LSs "https://raw.githubusercontent.com/Baka-SU/BakaSU/main/kernel/setup.sh" | bash -s main
    KSU_REPO="https://github.com/Baka-SU/BakaSU"
    SUSFS="${ENABLE_SUSFS}"
    if [ "${BAKASU_REF}" != "main" ]; then
      git -C KernelSU fetch -q --unshallow 2>/dev/null || true
      git -C KernelSU fetch -q origin "${BAKASU_REF}" 2>/dev/null || true
      git -C KernelSU checkout -q "${BAKASU_REF}" 2>/dev/null \
        || git -C KernelSU checkout -q FETCH_HEAD
    fi
    # Safety net: if upstream ever re-adds the unconditional SUSFS gate, pin to the
    # last good commit before the suspend instead of failing ~12 min into the build.
    if [ "${ENABLE_SUSFS}" == "true" ] \
       && grep -q 'Please wait susfs update' KernelSU/kernel/tools/susfs_compat.mk 2>/dev/null; then
      echo "::warning::BakaSU ${BAKASU_REF} has the SUSFS build gate again — falling back to pinned commit."
      git -C KernelSU fetch -q --unshallow 2>/dev/null || true
      git -C KernelSU checkout -q "5b76b884c75f729a220bb317aa4a4fc78f0e0e9c"
    fi
    KSU_BRANCH="$(git -C KernelSU rev-parse --short=8 HEAD)"
    echo "[+] BakaSU: ${BAKASU_REF} @ ${KSU_BRANCH} (SUSFS=${SUSFS})."
    ;;
  KernelSU-Next)
    curl -LSs "https://raw.githubusercontent.com/KernelSU-Next/KernelSU-Next/legacy/kernel/setup.sh" | bash -s legacy
    KSU_BRANCH="legacy"; SUSFS="false"
    KSU_REPO="https://github.com/KernelSU-Next/KernelSU-Next"
    # The kernel's manual hooks (fs/stat.c, fs/read_write.c, drivers/input/input.c) reference
    # static keys / a fstat helper that KernelSU-Next legacy does not define -> undefined
    # symbol at link time. Provide them here. Next gates its own handlers with its internal
    # flags (ksu_init_rc_hook / ksu_input_hook), so always-on keys are harmless.
    cat > KernelSU-Next/kernel/compat_baka_hooks.c << 'EOC'
#include <linux/jump_label.h>
#include <linux/types.h>

DEFINE_STATIC_KEY_TRUE(ksu_is_init_rc_hook_enabled);
DEFINE_STATIC_KEY_TRUE(ksu_is_input_hook_enabled);

void ksu_handle_vfs_fstat(int fd, loff_t *kstat_size_ptr)
{
}
EOC
    if ! grep -q "compat_baka_hooks.o" KernelSU-Next/kernel/Kbuild; then
      echo "kernelsu-objs += compat_baka_hooks.o" >> KernelSU-Next/kernel/Kbuild
    fi
    echo "[+] Added compat hooks shim for KernelSU-Next."
    if [ "${ENABLE_SUSFS}" == "true" ]; then
      echo "::warning::KernelSU-Next legacy branch has no SUSFS integration here — flag ignored."
    fi
    ;;
  KernelSU)
    curl -LSs "https://raw.githubusercontent.com/tiann/KernelSU/main/kernel/setup.sh" | bash -s main
    KSU_BRANCH="main"; SUSFS="false"
    KSU_REPO="https://github.com/tiann/KernelSU"
    if [ "${ENABLE_SUSFS}" == "true" ]; then
      echo "::warning::Original KernelSU has no built-in SUSFS support — flag ignored."
    fi
    ;;
  *)
    echo "::error::Unknown KSU variant: ${KSU_VARIANT_INPUT}"
    exit 1
    ;;
esac

if [ "${SUSFS}" == "true" ]; then
  BUILD_VARIANT="KernelSU + SUSFS"
else
  BUILD_VARIANT="KernelSU"
fi

{
  echo "KSU_VARIANT=${KSU_VARIANT_INPUT}"
  echo "KSU_BRANCH=${KSU_BRANCH}"
  echo "KSU_REPO=${KSU_REPO}"
  echo "SUSFS_ENABLED=${SUSFS}"
  echo "BUILD_VARIANT=${BUILD_VARIANT}"
} >> "$GITHUB_ENV"
