#!/usr/bin/env bash
set -e
source "$(dirname "$0")/common.sh"

# AK_GENERATE=1 replaces the AnyKernel repo's anykernel.sh with a generated boot-only RM6785 one and
# inserts the NEKO banner. Meant for a plain osm0sis AnyKernel3 template. Default 0: the default
# elohim-etz/AnyKernel3 already ships its own RM6785 anykernel.sh + banner (a longer device list).
# Identity shown in recovery. Overridable from the workflow `env:` block.
AK_KERNEL_STRING="${AK_KERNEL_STRING:-Neko Kernel}"
AK_AUTHOR="${AK_AUTHOR:-KitsuNeko}"
# Models allowed to flash (do.devicecheck=1), space separated
AK_DEVICES="${AK_DEVICES:-RMX2151 rmx2151 RMX2161 rmx2161 RMX2001 rmx2001 RMX2002 rmx2002 RMX2002L1 rmx2002L1 RMX2001L1 rmx2001L1 RMX2003 RMX2153 RMX2153L1 RMX2156 RMX2163 RMX2161L1 RMX2163L1 RMX3031 IN2023 GM1917 RM6785 rm6785 wasabi}"

# Writes a boot-only RM6785 anykernel.sh (no leftover example ramdisk code from upstream)
write_anykernel_sh() {
  local f="$1" i=0 d devlines=""
  for d in ${AK_DEVICES}; do i=$((i + 1)); devlines+="device.name${i}=${d}"$'\n'; done
  cat > "${f}" <<EOT
### AnyKernel3 Ramdisk Mod Script
## osm0sis @ xda-developers

### AnyKernel setup
# global properties
properties() { '
kernel.string=${AK_KERNEL_STRING}
do.devicecheck=1
do.modules=0
do.systemless=1
do.cleanup=1
do.cleanuponabort=0
${devlines}supported.versions=
supported.patchlevels=
supported.vendorpatchlevels=
'; } # end properties


### AnyKernel install
## boot files attributes
boot_attributes() {
set_perm_recursive 0 0 755 644 \$RAMDISK/*;
set_perm_recursive 0 0 750 750 \$RAMDISK/init* \$RAMDISK/sbin;
} # end attributes

# boot shell variables
BLOCK=/dev/block/by-name/boot;
IS_SLOT_DEVICE=0;
RAMDISK_COMPRESSION=auto;
PATCH_VBMETA_FLAG=auto;

# import functions/variables and setup patching - see for reference (DO NOT REMOVE)
. tools/ak3-core.sh;

# boot install
dump_boot;

write_boot;
## end boot install
EOT
}

# Inserts the banner (old AnyKernel zip style) into update-binary; returns 1 if the anchor is gone
patch_banner() {
  local ub="$1" banner="${TMPDIR:-/tmp}/ak_banner.$$"
  cat > "${banner}" <<EOT
ui_print "|----------------------------------------------|";
ui_print " ";
ui_print "|+-+-+-+-+-+-|  N E K O  -  K E R N E L  |+-+-++-+-+-|";
ui_print " ";
ui_print "|+-+-+-+-+-+-|\\\\___________________/|+-+-++-+-+-|";
ui_print " ";
ui_print "|+-+-+-+-+-+-+-+-+-|FOR RM6785|+-+-+-+-+-+-+-+-|";
ui_print " ";
ui_print "|+-+-+-+-+-+-+|By ${AK_AUTHOR}|+-+-+-+-+-+-|";
ui_print " ";
ui_print "|-------------|###################|------------|";
EOT
  python3 - "${ub}" "${banner}" <<'PY' || { rm -f "${banner}"; return 1; }
import sys
ub, bn = sys.argv[1], sys.argv[2]
s = open(ub).read()
b = open(bn).read()
anchor = 'ui_print " " "AnyKernel3 by osm0sis @ xda-developers" " ";'
if anchor not in s:
    sys.exit(1)
open(ub, "w").write(s.replace(anchor, b + "\n" + anchor, 1))
PY
  rm -f "${banner}"
}

# ── stage the kernel image ──────────────────────────────────────────────────
rm -f AnyKernel/Image AnyKernel/Image.gz AnyKernel/Image.gz-dtb
rm -f AnyKernel/*.zip
cp "${KERNEL_IMG}" AnyKernel/

if [ "${AK_GENERATE:-0}" = "1" ]; then
  write_anykernel_sh AnyKernel/anykernel.sh
  patch_banner AnyKernel/META-INF/com/google/android/update-binary \
    || log_warn "Banner not inserted (update-binary of this AnyKernel3 changed?). Zip is built without it."
  log_info "anykernel.sh generated: '${AK_KERNEL_STRING}' | By ${AK_AUTHOR} | device check: ${AK_DEVICES%% *} ..."
fi

cd AnyKernel
TIMESTAMP=$(date +"%Y%m%d-%H%M")

if [ "${KSU_VARIANT}" != "Stock" ]; then
  if [ "${SUSFS_ENABLED}" == "true" ]; then
    ZIP_NAME="${ZIP_NAME_PREFIX}-RM6785-${KSU_VARIANT}-SUSFS"
  else
    ZIP_NAME="${ZIP_NAME_PREFIX}-RM6785-${KSU_VARIANT}"
  fi
else
  ZIP_NAME="${ZIP_NAME_PREFIX}-RM6785-Stock"
fi
[ "${NOMOUNT:-0}" = "1" ] && ZIP_NAME="${ZIP_NAME}-NoMount"
[ "${STABLE:-0}" = "1" ]  && ZIP_NAME="${ZIP_NAME}-Stable"
ZIP_NAME="${ZIP_NAME}-${TIMESTAMP}"

zip -r9 "${ZIP_NAME}.zip" . -x '*.git*' 'README.md' '*placeholder' > /dev/null 2>&1

{
  echo "ZIP_NAME=${ZIP_NAME}"
  echo "ANYKERNEL_DIR=$(pwd)"
  echo "ZIP_PATH=$(pwd)/${ZIP_NAME}.zip"
} >> "$GITHUB_ENV"
log_success "Zip: ${ZIP_NAME}.zip ($(du -h "${ZIP_NAME}.zip" | cut -f1))"
