#!/usr/bin/env bash
set -e
source "$(dirname "$0")/telegram_common.sh"

if [ -z "${TELEGRAM_BOT_TOKEN}" ] || [ -z "${TELEGRAM_CHAT_ID}" ]; then
  echo "Telegram secrets are not set, skipping."; exit 0
fi

duration_min=$(( BUILD_DURATION / 60 ))
duration_sec=$(( BUILD_DURATION % 60 ))

ZIP_ESC=$(esc "${ZIP_NAME}.zip")
BRANCH_ESC=$(esc "${KERNEL_BRANCH}")
COMMIT_MSG_ESC=$(esc "${KERNEL_COMMIT_MSG}")
COMMIT_URL_ESC=$(esc_url "${KERNEL_COMMIT_URL}")
TIME_ESC=$(esc "${duration_min}m ${duration_sec}s")
KSU_ESC=$(esc "${KSU_VARIANT}")
RUN_URL_ESC=$(esc_url "${GITHUB_SERVER_URL}/${GITHUB_REPOSITORY}/actions/runs/${GITHUB_RUN_ID}")

# ── build variant (+ NoMount / Stable) ──────────────────────────────────────
VARIANT="${BUILD_VARIANT}"
if [ "${STABLE:-0}" = "1" ]; then
  VARIANT="${VARIANT} (Stable)"
elif [ "${NOMOUNT:-0}" = "1" ]; then
  VARIANT="${VARIANT} + NoMount (${NOMOUNT_REF} @ ${NOMOUNT_COMMIT:--})"
fi
VARIANT_ESC=$(esc "${VARIANT}")

# ── memory tuning summary ───────────────────────────────────────────────────
swap="off"
if [ "${SWAPPINESS_PATCH:-0}" = "1" ]; then
  [ "${SWAPPINESS_LOCK:-0}" = "1" ] && swap="${SWAPPINESS_DEFAULT} (locked)" || swap="${SWAPPINESS_DEFAULT} (unlocked)"
fi
zr="off"
if [ "${LOWRAM:-0}" = "1" ]; then
  zr="${ZRAM_COMP}"
  [ "${ZRAM_MIN_PERCENT:-0}" != "0" ] && zr="${ZRAM_COMP}, min ${ZRAM_MIN_PERCENT}% RAM"
elif [ "${ZRAM_MIN_PERCENT:-0}" != "0" ]; then
  zr="min ${ZRAM_MIN_PERCENT}% RAM"
fi

# ── toolchain ───────────────────────────────────────────────────────────────
case "${CLANG_TYPE:-}" in
  aosp) TOOLCHAIN_NAME="AOSP" ;; neutron) TOOLCHAIN_NAME="Neutron" ;; greenforce) TOOLCHAIN_NAME="Greenforce" ;;
  weebx) TOOLCHAIN_NAME="WeebX" ;; zyc) TOOLCHAIN_NAME="ZyC" ;; *) TOOLCHAIN_NAME="${CLANG_TOOLCHAIN:-Clang}" ;;
esac

if [ -n "${CLANG_PATH}" ] && [ -x "${CLANG_PATH}/clang" ]; then
  CLANG_VER_STR=$("${CLANG_PATH}/clang" --version | head -n 1 | sed -n 's/.*clang version \([0-9.]*\).*/\1/p')
  [ -z "$CLANG_VER_STR" ] && CLANG_VER_STR="unknown"
  CLANG_ESC=$(esc "${TOOLCHAIN_NAME} ${CLANG_VER_STR}${CLANG_TAG:+ (tag ${CLANG_TAG})}")
else
  CLANG_ESC=$(esc "N/A")
fi

CAPTION_FILE=$(mktemp)

printf '✅ *Build Successful* ✅\n\n'                          >> "$CAPTION_FILE"
printf '%s\n\n'              "${ZIP_ESC}"                     >> "$CAPTION_FILE"
printf '*Branch:* %s\n'      "${BRANCH_ESC}"                  >> "$CAPTION_FILE"
printf '*Commit:* [%s](%s)\n' "${COMMIT_MSG_ESC}" "${COMMIT_URL_ESC}" >> "$CAPTION_FILE"
printf '*Time:* %s\n'        "${TIME_ESC}"                    >> "$CAPTION_FILE"
printf '*Build Variant:* %s\n' "${VARIANT_ESC}"               >> "$CAPTION_FILE"
printf '*Kernel:* %s\n'      "$(esc "${KERNEL_RELEASE:-?}")"  >> "$CAPTION_FILE"
printf '*KernelSU:* %s\n'    "${KSU_ESC}"                     >> "$CAPTION_FILE"
printf '*Swappiness:* %s\n'  "$(esc "${swap}")"               >> "$CAPTION_FILE"
printf '*Zram:* %s\n'        "$(esc "${zr}")"                 >> "$CAPTION_FILE"
printf '*Clang:* %s\n'       "${CLANG_ESC}"                   >> "$CAPTION_FILE"

if [ "${KSU_VARIANT}" != "Stock" ]; then
  printf '*Manager:* [Download](%s)\n' "$(esc_url "${KSU_REPO}/releases/latest")" >> "$CAPTION_FILE"
fi

if [ -n "${CUSTOM_NOTE}" ]; then
  printf '\n*Note:* %s\n' "$(esc "${CUSTOM_NOTE}")"           >> "$CAPTION_FILE"
fi

printf '\n[View Run](%s)\n' "${RUN_URL_ESC}"                  >> "$CAPTION_FILE"

resp="$(curl -sS --max-time 300 -X POST "https://api.telegram.org/bot${TELEGRAM_BOT_TOKEN}/sendDocument" \
  -F chat_id="${TELEGRAM_CHAT_ID}" \
  -F parse_mode="MarkdownV2" \
  -F "caption=<${CAPTION_FILE}" \
  -F "document=@${ZIP_PATH}" || true)"

rm -f "$CAPTION_FILE"

# A Telegram hiccup must not turn a good build red
if printf '%s' "$resp" | grep -q '"ok":true'; then
  echo "ZIP sent to Telegram."
else
  echo "::warning::Telegram rejected the upload (build itself succeeded): $resp"
fi
