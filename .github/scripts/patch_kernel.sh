#!/usr/bin/env bash
# Source-level patches applied to the cloned kernel (all idempotent):
#   swappiness, VM tuning, DTB-only Image.gz-dtb, zram compressor, zram minimum size.
# Toggles come from resolve_options.sh (SWAPPINESS_PATCH, VM_TUNE, LOWRAM, ZRAM_MIN_PERCENT, ...).
set -uo pipefail
source "$(dirname "$0")/common.sh"
cd "${KERNEL_DIR}" || exit 1

DTB_ONLY="${DTB_ONLY:-1}"
VM_PAGE_CLUSTER="${VM_PAGE_CLUSTER:-0}"
VM_WATERMARK_SCALE="${VM_WATERMARK_SCALE:-30}"

# ── swappiness (max 100 -> 200, default value, optional lock) ──────────────
patch_swappiness() {
  [ "${SWAPPINESS_PATCH:-0}" = "1" ] || return 0
  log_info "Patch swappiness: max 200, default ${SWAPPINESS_DEFAULT}, lock=${SWAPPINESS_LOCK}"
  python3 - "${KERNEL_DIR}" "${SWAPPINESS_DEFAULT}" "${SWAPPINESS_LOCK}" <<'PY' 2>&1 | tee -a "${BUILD_LOG}"
import re, sys
root, default, lock = sys.argv[1], sys.argv[2], sys.argv[3] == "1"
failed = False

def edit(path, fn, label):
    global failed
    f = f"{root}/{path}"
    src = open(f).read()
    out, msg = fn(src)
    if out is None:
        print(f"[ERROR] {path}: {label} -> pattern not found (different source?)")
        failed = True
        return
    if out != src:
        open(f, "w").write(out)
    print(f"[PATCH] {path}: {label} ({msg})")

# kernel/sysctl.c : limit 200 (+ mode 0444 when locked)
def sysctl(src):
    if "static int two_hundred" not in src:
        src, n = re.subn(r"(static int one_hundred = 100;\n)", r"\1static int two_hundred = 200;\n", src, count=1)
        if n == 0:
            return None, ""
    m = re.search(r'\{\s*\.procname\s*=\s*"swappiness",.*?\n\t\},', src, re.S)
    if not m:
        return None, ""
    blk = m.group(0)
    new = blk.replace("&one_hundred", "&two_hundred")
    if lock:
        new = re.sub(r"\.mode(\s*)= 0[0-7]{3}", r".mode\1= 0444", new, count=1)
    return src.replace(blk, new, 1), ("max=200, mode=" + ("0444" if lock else "unchanged"))
edit("kernel/sysctl.c", sysctl, "sysctl vm.swappiness")

# mm/memcontrol.c : limit 200 (+ ignore writes to the root cgroup when locked)
def memcg(src):
    m = re.search(r"static int mem_cgroup_swappiness_write\(.*?\n\}\n", src, re.S)
    if not m:
        return None, ""
    fn = m.group(0)
    new = fn.replace("if (val > 100)", "if (val > 200)")
    if lock:
        new = re.sub(
            r"\tif \(css->parent\)\n\t\tmemcg->swappiness = val;\n\telse\n\t\tvm_swappiness = val;\n",
            "\tif (css->parent)\n\t\tmemcg->swappiness = val;\n"
            "\t/* root cgroup: global value is locked, write ignored but reported as success */\n",
            new)
        if "vm_swappiness = val" in new:
            return None, ""
    return src.replace(fn, new, 1), "max=200" + (", root ignored" if lock else "")
edit("mm/memcontrol.c", memcg, "memory.swappiness")

# mm/vmscan.c : default value
def vmscan(src):
    new, n = re.subn(r"int vm_swappiness = \d+;", f"int vm_swappiness = {default};", src, count=1)
    return (new, f"default={default}") if n else (None, "")
edit("mm/vmscan.c", vmscan, "vm_swappiness default")

sys.exit(1 if failed else 0)
PY
  [ "${PIPESTATUS[0]}" -eq 0 ] || { log_error "Swappiness patch failed, stopping the build."; exit 1; }
}

# ── VM defaults for zram + gaming ──────────────────────────────────────────
patch_vm_tuning() {
  [ "${VM_TUNE:-0}" = "1" ] || return 0
  local v
  for v in "${VM_PAGE_CLUSTER}:0:6:VM_PAGE_CLUSTER" "${VM_WATERMARK_SCALE}:1:1000:VM_WATERMARK_SCALE"; do
    local val="${v%%:*}" rest="${v#*:}"
    local lo="${rest%%:*}"; rest="${rest#*:}"
    local hi="${rest%%:*}" name="${rest#*:}"
    if ! [[ "${val}" =~ ^[0-9]+$ ]] || [ "${val}" -lt "${lo}" ] || [ "${val}" -gt "${hi}" ]; then
      log_error "${name} must be ${lo}-${hi} (got '${val}')"; exit 1
    fi
  done
  local swp="${KERNEL_DIR}/mm/swap.c" pga="${KERNEL_DIR}/mm/page_alloc.c"
  if grep -qE '^[[:space:]]+page_cluster = [0-9]+;' "${swp}" && grep -qE '^int watermark_scale_factor = [0-9]+;' "${pga}"; then
    sed -i -E "s/^([[:space:]]+page_cluster = )[0-9]+;/\1${VM_PAGE_CLUSTER};/" "${swp}"
    sed -i -E "s/^(int watermark_scale_factor = )[0-9]+;/\1${VM_WATERMARK_SCALE};/" "${pga}"
    log_info "VM tuning: page-cluster=${VM_PAGE_CLUSTER}, watermark_scale_factor=${VM_WATERMARK_SCALE}"
  else
    log_warn "VM code pattern (swap.c / page_alloc.c) not recognised, VM tuning skipped."
  fi
}

# ── Image.gz-dtb with only the main DTB (4.19 Makefile also appends .dtbo overlays) ──
patch_dtb_append() {
  [ "${DTB_ONLY}" = "1" ] || return 0
  [ -f "${KERNEL_DIR}/arch/arm64/boot/Makefile" ] || return 0
  python3 - "${KERNEL_DIR}/arch/arm64/boot/Makefile" <<'PY' 2>&1 | tee -a "${BUILD_LOG}"
import sys
p = sys.argv[1]
s = open(p).read()
obj = "DTB_OBJS := $(addprefix $(obj)/dts/,$(DTB_LIST))\n"
i_obj = s.find(obj)
i_dtbo = s.find("DTBO_NAMES :=")
if i_obj < 0 or i_dtbo < 0:
    print("[PATCH] arch/arm64/boot/Makefile: pattern not recognised, skipped")
    sys.exit(0)
if i_obj < i_dtbo:
    print("[PATCH] arch/arm64/boot/Makefile: already main-DTB only, no change")
    sys.exit(0)
s = s.replace(obj, "", 1)
s = s.replace("DTBO_NAMES :=", obj + "\nDTBO_NAMES :=", 1)
open(p, "w").write(s)
print("[PATCH] arch/arm64/boot/Makefile: Image.gz-dtb holds only the main DTB (overlays not appended)")
PY
}

# ── zram default compressor (4.19: hard-coded in zram_drv.c, 4.14: Kconfig ZRAM_DEF_COMP_*) ──
patch_zram_compressor() {
  [ "${LOWRAM:-0}" = "1" ] || return 0
  case "${ZRAM_COMP}" in
    lzo|lzo-rle|lz4|lz4hc|zstd) ;;
    *) log_error "Invalid zram compressor: '${ZRAM_COMP}' (lzo lzo-rle lz4 lz4hc zstd)"; exit 1 ;;
  esac
  local f="${KERNEL_DIR}/drivers/block/zram/zram_drv.c"
  local k="${KERNEL_DIR}/drivers/block/zram/Kconfig"
  local mode
  if grep -qE 'static const char \*default_compressor = "[^"]*";' "${f}" 2>/dev/null; then
    sed -i -E "s|(static const char \*default_compressor = )\"[^\"]*\";|\1\"${ZRAM_COMP}\";|" "${f}"
    mode="source"; log_info "Default zram compressor (source): ${ZRAM_COMP}"
  elif grep -q 'config ZRAM_DEF_COMP_LZ4' "${k}" 2>/dev/null; then
    mode="kconfig"; log_info "Default zram compressor (Kconfig): ${ZRAM_COMP}"
  else
    mode="none"; log_warn "default_compressor pattern not recognised, zram compressor unchanged."
  fi
  set_env ZRAM_COMP_MODE "${mode}"
}

# ── zram minimum size, % of RAM ────────────────────────────────────────────
patch_zram_size() {
  [ "${ZRAM_MIN_PERCENT:-0}" = "0" ] && return 0
  local f="${KERNEL_DIR}/drivers/block/zram/zram_drv.c"
  [ -f "${f}" ] || { log_warn "zram_drv.c not found, zram size unchanged."; return 0; }
  python3 - "${f}" "${ZRAM_MIN_PERCENT}" <<'PY' 2>&1 | tee -a "${BUILD_LOG}"
import re, sys
p, pct = sys.argv[1], sys.argv[2]
s = open(p).read()
define = f"#define NEKO_ZRAM_MIN_PCT {pct}\n"
if "NEKO_ZRAM_MIN_PCT" in s:
    open(p, "w").write(re.sub(r"#define NEKO_ZRAM_MIN_PCT \d+\n", define, s, count=1))
    print(f"[PATCH] zram_drv.c: minimum zram size updated -> {pct}% RAM (already patched)")
    sys.exit(0)
inc = '#include "zram_drv.h"\n'
m = re.search(r"(\tdisksize = memparse\(buf, NULL\);\n\tif \(!disksize\)\n\t\treturn -EINVAL;\n)", s)
if inc not in s or not m:
    print("[WARN] zram_drv.c: disksize_store pattern not recognised, zram size unchanged")
    sys.exit(3)
block = (
    "\n\t/* NEKO: minimum zram size = NEKO_ZRAM_MIN_PCT% of RAM (userspace may ask for more) */\n"
    "\t{\n"
    "\t\tstruct sysinfo neko_si;\n"
    "\t\tu64 neko_min;\n\n"
    "\t\tsi_meminfo(&neko_si);\n"
    "\t\tneko_min = (u64)neko_si.totalram * neko_si.mem_unit / 100 * NEKO_ZRAM_MIN_PCT;\n"
    "\t\tif (disksize < neko_min)\n"
    "\t\t\tdisksize = neko_min;\n"
    "\t}\n"
)
s = s.replace(inc, inc + define, 1)
s = s.replace(m.group(1), m.group(1) + block, 1)
open(p, "w").write(s)
print(f"[PATCH] zram_drv.c: minimum zram size = {pct}% of RAM")
PY
  [ "${PIPESTATUS[0]}" -eq 0 ] || log_warn "zram size patch skipped (see message above)."
}

patch_swappiness
patch_vm_tuning
patch_dtb_append
patch_zram_compressor
patch_zram_size
log_success "Source patches done."
