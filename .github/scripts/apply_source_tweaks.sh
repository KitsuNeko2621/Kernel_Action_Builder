#!/usr/bin/env bash
# Patch source kernel 4.14: swappiness (maks 200 + kunci), VM tuning zram,
# kompresor & ukuran zram. Opsi .config (hemat RAM, localversion, NoMount)
# diterapkan terpisah di kernel_config_tweaks.sh setelah defconfig dibuat.
set -euo pipefail
cd "${KERNEL_DIR}"

log()  { echo "[TWEAK] $*";  [ -n "${BUILD_LOG:-}" ] && echo "[TWEAK] $*" >> "${BUILD_LOG}"; return 0; }
warn() { echo "::warning::$*"; [ -n "${BUILD_LOG:-}" ] && echo "[WARN] $*" >> "${BUILD_LOG}"; return 0; }
die()  { echo "::error::$*"; exit 1; }

SWAPPINESS_DEFAULT="${INPUT_SWAPPINESS_DEFAULT:-off}"
SWAPPINESS_LOCK="${INPUT_SWAPPINESS_LOCK:-false}"
LOWRAM_MODE="${INPUT_LOWRAM_MODE:-lz4}"
ZRAM_MIN_PERCENT="${INPUT_ZRAM_SIZE_PERCENT:-0}"
VM_TUNE="${INPUT_VM_TUNE:-false}"
AGGRESSIVE="${INPUT_AGGRESSIVE_DEBUG_OFF:-false}"
LOCALVERSION_SUFFIX="${INPUT_LOCALVERSION:-}"

VM_PAGE_CLUSTER=0
VM_WATERMARK_SCALE=30

# ── Validasi input ───────────────────────────────────────────────────────────
if [ "${SWAPPINESS_DEFAULT}" != "off" ]; then
  [[ "${SWAPPINESS_DEFAULT}" =~ ^[0-9]+$ ]] && [ "${SWAPPINESS_DEFAULT}" -le 200 ] \
    || die "swappiness_default harus 0-200 atau 'off' (sekarang: '${SWAPPINESS_DEFAULT}')"
fi
[[ "${ZRAM_MIN_PERCENT}" =~ ^[0-9]+$ ]] && [ "${ZRAM_MIN_PERCENT}" -le 200 ] \
  || die "zram_size_percent harus 0-200 (sekarang: '${ZRAM_MIN_PERCENT}')"
if [[ "${LOCALVERSION_SUFFIX}" =~ [[:space:]] ]] || [ "${#LOCALVERSION_SUFFIX}" -gt 64 ]; then
  die "localversion tidak boleh mengandung spasi dan maksimal 64 karakter: '${LOCALVERSION_SUFFIX}'"
fi

LOWRAM=1; ZRAM_COMP="${LOWRAM_MODE}"
if [ "${LOWRAM_MODE}" = "off" ]; then LOWRAM=0; ZRAM_COMP=""; fi
case "${ZRAM_COMP}" in ""|lzo|lz4|lz4hc|zstd) ;; *) die "lowram_mode tidak valid: '${ZRAM_COMP}'" ;; esac

# ── 1. Swappiness ────────────────────────────────────────────────────────────
patch_swappiness() {
  if [ "${SWAPPINESS_DEFAULT}" = "off" ]; then
    log "Swappiness: tidak diubah (off)"
    [ "${SWAPPINESS_LOCK}" = "true" ] && warn "swappiness_lock diabaikan karena swappiness_default = off"
    return 0
  fi
  local lock=0; [ "${SWAPPINESS_LOCK}" = "true" ] && lock=1
  log "Swappiness: maks 200, default ${SWAPPINESS_DEFAULT}, kunci=${SWAPPINESS_LOCK}"
  python3 - "${KERNEL_DIR}" "${SWAPPINESS_DEFAULT}" "${lock}" <<'PY'
import re, sys
root, default, lock = sys.argv[1], sys.argv[2], sys.argv[3] == "1"
failed = False

def edit(path, fn, label):
    global failed
    f = f"{root}/{path}"
    src = open(f).read()
    out, msg = fn(src)
    if out is None:
        print(f"[ERROR] {path}: {label} -> pola tidak ditemukan (source berbeda?)")
        failed = True
        return
    if out != src:
        open(f, "w").write(out)
    print(f"[PATCH] {path}: {label} ({msg})")

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
    return src.replace(blk, new, 1), "maks=200, mode=" + ("0444" if lock else "tetap")
edit("kernel/sysctl.c", sysctl, "sysctl vm.swappiness")

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
            "\t/* root cgroup: nilai global dikunci, tulisan diabaikan tapi dianggap sukses */\n",
            new)
        if "vm_swappiness = val" in new:
            return None, ""
    return src.replace(fn, new, 1), "maks=200" + (", root diabaikan" if lock else "")
edit("mm/memcontrol.c", memcg, "memory.swappiness")

def vmscan(src):
    new, n = re.subn(r"int vm_swappiness = \d+;", f"int vm_swappiness = {default};", src, count=1)
    return (new, f"default={default}") if n else (None, "")
edit("mm/vmscan.c", vmscan, "vm_swappiness default")

sys.exit(1 if failed else 0)
PY
}

# ── 2. VM tuning untuk zram + gaming ─────────────────────────────────────────
patch_vm_tuning() {
  [ "${VM_TUNE}" = "true" ] || { log "VM tuning: off"; return 0; }
  local swp="mm/swap.c" pga="mm/page_alloc.c"
  if grep -qE '^[[:space:]]+page_cluster = [0-9]+;' "${swp}" && grep -qE '^int watermark_scale_factor = [0-9]+;' "${pga}"; then
    sed -i -E "s/^([[:space:]]+page_cluster = )[0-9]+;/\1${VM_PAGE_CLUSTER};/" "${swp}"
    sed -i -E "s/^(int watermark_scale_factor = )[0-9]+;/\1${VM_WATERMARK_SCALE};/" "${pga}"
    log "VM tuning: page-cluster=${VM_PAGE_CLUSTER}, watermark_scale_factor=${VM_WATERMARK_SCALE}"
  else
    warn "Pola kode VM (swap.c / page_alloc.c) tidak dikenali, VM tuning dilewati."
    VM_TUNE=false
  fi
}

# ── 3. Kompresor zram default ────────────────────────────────────────────────
# 4.14: biasanya hardcode default_compressor = "lzo" di zram_drv.c.
# Kalau source sudah punya opsi Kconfig ZRAM_DEF_COMP_*, dipakai lewat .config.
ZRAM_COMP_MODE="none"
patch_zram_compressor() {
  [ "${LOWRAM}" = "1" ] || return 0
  local f="drivers/block/zram/zram_drv.c" k="drivers/block/zram/Kconfig"
  if grep -qE 'static const char \*default_compressor = "[^"]*";' "${f}"; then
    sed -i -E "s|(static const char \*default_compressor = )\"[^\"]*\";|\1\"${ZRAM_COMP}\";|" "${f}"
    ZRAM_COMP_MODE="source"
    log "Kompresor zram default (source): ${ZRAM_COMP}"
  elif grep -q 'config ZRAM_DEF_COMP_LZ4' "${k}" 2>/dev/null; then
    ZRAM_COMP_MODE="kconfig"
    log "Kompresor zram default (Kconfig): ${ZRAM_COMP}"
  else
    warn "Pola default_compressor zram tidak dikenali, kompresor tidak diubah."
  fi
}

# ── 4. Ukuran zram minimum ───────────────────────────────────────────────────
patch_zram_size() {
  [ "${ZRAM_MIN_PERCENT}" = "0" ] && { log "Ukuran zram: tidak diubah"; return 0; }
  local f="drivers/block/zram/zram_drv.c"
  [ -f "${f}" ] || { warn "zram_drv.c tidak ditemukan, ukuran zram tidak diubah."; return 0; }
  set +e
  python3 - "${f}" "${ZRAM_MIN_PERCENT}" <<'PY'
import re, sys
p, pct = sys.argv[1], sys.argv[2]
s = open(p).read()
define = f"#define NEKO_ZRAM_MIN_PCT {pct}\n"
if "NEKO_ZRAM_MIN_PCT" in s:
    open(p, "w").write(re.sub(r"#define NEKO_ZRAM_MIN_PCT \d+\n", define, s, count=1))
    print(f"[PATCH] zram_drv.c: ukuran minimum zram diperbarui -> {pct}% RAM")
    sys.exit(0)
inc = '#include "zram_drv.h"\n'
m = re.search(r"(\tdisksize = memparse\(buf, NULL\);\n\tif \(!disksize\)\n\t\treturn -EINVAL;\n)", s)
if inc not in s or not m:
    print("[WARN] zram_drv.c: pola disksize_store tidak dikenali, ukuran zram tidak diubah")
    sys.exit(3)
block = (
    "\n\t/* NEKO: ukuran zram minimum = NEKO_ZRAM_MIN_PCT% dari RAM (ROM boleh minta lebih besar) */\n"
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
print(f"[PATCH] zram_drv.c: ukuran minimum zram = {pct}% dari RAM")
PY
  local rc=$?
  set -e
  if [ "${rc}" -ne 0 ]; then
    warn "Patch ukuran zram dilewati (pola kode tidak cocok)."
    ZRAM_MIN_PERCENT=0
  fi
}

patch_swappiness
patch_vm_tuning
patch_zram_compressor
patch_zram_size

# ── Ringkasan untuk Telegram & tahap config ──────────────────────────────────
SUMMARY=""
add_summary() { if [ -n "${SUMMARY}" ]; then SUMMARY="${SUMMARY}, $1"; else SUMMARY="$1"; fi; }
if [ "${SWAPPINESS_DEFAULT}" != "off" ]; then
  s_txt="swappiness ${SWAPPINESS_DEFAULT}"
  if [ "${SWAPPINESS_LOCK}" = "true" ]; then s_txt="${s_txt} (lock)"; fi
  add_summary "${s_txt}"
fi
if [ "${ZRAM_MIN_PERCENT}" != "0" ]; then add_summary "zram min ${ZRAM_MIN_PERCENT}%"; fi
if [ "${LOWRAM}" = "1" ]; then
  l_txt="lowram/${ZRAM_COMP}"
  if [ "${AGGRESSIVE}" = "true" ]; then l_txt="${l_txt}+aggressive"; fi
  add_summary "${l_txt}"
fi
if [ "${VM_TUNE}" = "true" ]; then add_summary "vm-tune"; fi
SUMMARY_STR="${SUMMARY:-none}"
LOWRAM_AGGRESSIVE=0
if [ "${AGGRESSIVE}" = "true" ]; then LOWRAM_AGGRESSIVE=1; fi

{
  echo "LOWRAM=${LOWRAM}"
  echo "ZRAM_COMP=${ZRAM_COMP}"
  echo "ZRAM_COMP_MODE=${ZRAM_COMP_MODE}"
  echo "LOWRAM_AGGRESSIVE=${LOWRAM_AGGRESSIVE}"
  echo "KERNEL_LOCALVERSION=${LOCALVERSION_SUFFIX}"
  echo "TWEAK_SUMMARY=${SUMMARY_STR}"
} >> "${GITHUB_ENV}"

log "Ringkasan: ${SUMMARY_STR}"
