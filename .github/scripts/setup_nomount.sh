#!/usr/bin/env bash
# Integrates NoMount (VFS path redirection, https://github.com/maxsteeel/nomount) into the kernel source
# (equivalent to NoMount's own kernel/setup.sh, without "curl | bash").
# CONFIG_NOMOUNT itself is switched on later in build_kernel.sh.
set -uo pipefail
source "$(dirname "$0")/common.sh"

[ "${NOMOUNT:-0}" = "1" ] || { log_info "NoMount: disabled."; exit 0; }

NOMOUNT_REPO="${NOMOUNT_REPO:-https://github.com/maxsteeel/nomount.git}"
NOMOUNT_REF="${NOMOUNT_REF:-dev}"
nm="${KERNEL_DIR}/NoMount"; fs="${KERNEL_DIR}/fs"

[ -d "${fs}" ] || { log_error "fs/ directory not found in ${KERNEL_DIR}"; exit 1; }

log_info "NoMount: preparing (${NOMOUNT_REF})..."
rm -rf "${nm}"
git clone -q "${NOMOUNT_REPO}" "${nm}" || { log_error "Failed to clone NoMount (${NOMOUNT_REPO})."; exit 1; }
if git -C "${nm}" rev-parse --verify -q "origin/${NOMOUNT_REF}" >/dev/null; then
  git -C "${nm}" checkout -q -f --detach "origin/${NOMOUNT_REF}"
else
  git -C "${nm}" checkout -q -f "${NOMOUNT_REF}" || { log_error "NoMount: ref '${NOMOUNT_REF}' not found."; exit 1; }
fi
[ -f "${nm}/kernel/src/nomount.c" ] || { log_error "NoMount: kernel/src/nomount.c missing."; exit 1; }

ln -sfn ../NoMount/kernel/src "${fs}/nomount"
if ! grep -q "nomount" "${fs}/Makefile"; then
  printf '\nobj-$(CONFIG_NOMOUNT) += nomount/\n' >> "${fs}/Makefile"
fi
if ! grep -q 'source "fs/nomount/Kconfig"' "${fs}/Kconfig"; then
  awk '
    /^endmenu/ { last = NR }
    { lines[NR] = $0 }
    END { for (i = 1; i <= NR; i++) { if (i == last) print "source \"fs/nomount/Kconfig\""; print lines[i] } }
  ' "${fs}/Kconfig" > "${fs}/Kconfig.tmp" && mv "${fs}/Kconfig.tmp" "${fs}/Kconfig"
fi
grep -q 'source "fs/nomount/Kconfig"' "${fs}/Kconfig" || { log_error "NoMount: failed to patch fs/Kconfig."; exit 1; }

log_success "NoMount: $(git -C "${nm}" log -1 --format='%h %s')"
set_env NOMOUNT_COMMIT "$(git -C "${nm}" rev-parse --short HEAD)"
