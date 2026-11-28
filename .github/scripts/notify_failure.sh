#!/usr/bin/env bash
set -e
source "$(dirname "$0")/telegram_common.sh"

if [ -z "${TELEGRAM_BOT_TOKEN}" ] || [ -z "${TELEGRAM_CHAT_ID}" ]; then
  echo "Telegram secrets are not set, skipping."; exit 0
fi

BRANCH=$(esc "${KERNEL_BRANCH:-${INPUT_KERNEL_BRANCH:-default}}")
RUN_URL_ESC=$(esc_url "${GITHUB_SERVER_URL}/${GITHUB_REPOSITORY}/actions/runs/${GITHUB_RUN_ID}")

# The failure may have happened before the options were resolved: fall back to raw inputs
KSU_ON="${ENABLE_KSU:-${INPUT_ENABLE_KSU:-false}}"
if [ "${INPUT_STABLE_MODE:-false}" = "true" ]; then KSU_ON="false"; fi

if [ -n "${BUILD_VARIANT}" ]; then
  VARIANT_TAG="${BUILD_VARIANT}"
elif [ "${KSU_ON}" == "true" ]; then
  if [ "${INPUT_ENABLE_SUSFS}" == "true" ] && [ "${KSU_VARIANT_INPUT}" != "xxKSU" ]; then
    VARIANT_TAG="KernelSU + SUSFS"
  else
    VARIANT_TAG="KernelSU"
  fi
else
  VARIANT_TAG="Normal"
fi

if [ "${INPUT_STABLE_MODE:-false}" = "true" ]; then
  VARIANT_TAG="${VARIANT_TAG} (Stable)"
elif [ "${NOMOUNT:-$([ "${INPUT_ENABLE_NOMOUNT:-false}" = "true" ] && echo 1 || echo 0)}" = "1" ]; then
  VARIANT_TAG="${VARIANT_TAG} + NoMount"
fi

MSG_FILE=$(mktemp)

printf '❌ *Build Failed* ❌\n\n'                 >> "$MSG_FILE"
printf '*Branch:* %s\n'        "${BRANCH}"       >> "$MSG_FILE"

if [ -n "${KERNEL_COMMIT_MSG}" ]; then
  if [ -n "${KERNEL_COMMIT_URL}" ]; then
    printf '*Commit:* [%s](%s)\n' "$(esc "${KERNEL_COMMIT_MSG}")" "$(esc_url "${KERNEL_COMMIT_URL}")" >> "$MSG_FILE"
  else
    printf '*Commit:* %s\n' "$(esc "${KERNEL_COMMIT_MSG}")" >> "$MSG_FILE"
  fi
fi

printf '*Build Variant:* %s\n' "$(esc "${VARIANT_TAG}")" >> "$MSG_FILE"

if [ "${KSU_ON}" == "true" ]; then
  printf '*KernelSU:* %s\n' "$(esc "${KSU_VARIANT_INPUT:-N/A}")" >> "$MSG_FILE"
fi

if [ -n "${CUSTOM_NOTE}" ]; then
  printf '\n*Note:* %s\n' "$(esc "${CUSTOM_NOTE}")" >> "$MSG_FILE"
fi

printf '\n[View Logs](%s)\n' "${RUN_URL_ESC}"    >> "$MSG_FILE"

resp="$(curl -sS --max-time 60 -X POST "https://api.telegram.org/bot${TELEGRAM_BOT_TOKEN}/sendMessage" \
  -d chat_id="${TELEGRAM_CHAT_ID}" \
  -d parse_mode="MarkdownV2" \
  -d disable_web_page_preview=true \
  --data-urlencode "text@${MSG_FILE}" || true)"

rm -f "$MSG_FILE"

if printf '%s' "$resp" | grep -q '"ok":true'; then
  echo "Failure notification sent to Telegram."
else
  echo "::warning::Telegram rejected the message: $resp"
fi
