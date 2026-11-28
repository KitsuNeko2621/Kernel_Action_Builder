#!/usr/bin/env bash
set -e
source "$(dirname "$0")/common.sh"
cd "${KERNEL_DIR}"

boot="out/arch/arm64/boot"

# Image.gz-dtb (DTB appended) is preferred when it exists; PREFER_DTB_IMAGE=0 forces plain Image.gz
if   [ "${PREFER_DTB_IMAGE:-1}" = "1" ] && [ -f "${boot}/Image.gz-dtb" ]; then KERNEL_IMG="${boot}/Image.gz-dtb"
elif [ -f "${boot}/Image.gz" ]; then KERNEL_IMG="${boot}/Image.gz"
elif [ -f "${boot}/Image.gz-dtb" ]; then KERNEL_IMG="${boot}/Image.gz-dtb"
elif [ -f "${boot}/Image" ];    then KERNEL_IMG="${boot}/Image"
else
  log_error "No kernel image found in ${boot} — build failed. See: grep -iE 'error:' logs/errors.log"
  exit 1
fi

IMAGE_SIZE_MB=$(echo "scale=2; $(stat -c%s "${KERNEL_IMG}") / 1048576" | bc)
{
  echo "KERNEL_IMG=${KERNEL_DIR}/${KERNEL_IMG}"
  echo "KERNEL_IMG_NAME=$(basename "${KERNEL_IMG}")"
  echo "IMAGE_SIZE_MB=${IMAGE_SIZE_MB}"
  echo "KERNEL_RELEASE=$(cat out/include/config/kernel.release 2>/dev/null || echo '?')"
} >> "$GITHUB_ENV"
log_success "$(basename "${KERNEL_IMG}") OK (${IMAGE_SIZE_MB} MB)"
