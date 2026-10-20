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
    curl -LSs "https://raw.githubusercontent.com/Baka-SU/BakaSU/main/kernel/setup.sh" | bash -s main
    KSU_BRANCH="main"
    KSU_REPO="https://github.com/Baka-SU/BakaSU"
    SUSFS="${ENABLE_SUSFS}"
    ;;
  KernelSU-Next)
    curl -LSs "https://raw.githubusercontent.com/KernelSU-Next/KernelSU-Next/legacy/kernel/setup.sh" | bash -s legacy
    KSU_BRANCH="legacy"; SUSFS="false"
    KSU_REPO="https://github.com/KernelSU-Next/KernelSU-Next"
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
