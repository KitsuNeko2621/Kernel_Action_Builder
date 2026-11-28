#!/usr/bin/env bash
# Prepares the Clang toolchain selected by CLANG_TOOLCHAIN:
#   AOSP (cloned by the workflow) | Neutron | Greenforce | WeebX | ZyC
# GF_CLANG_VERSION applies to Greenforce / ZyC / WeebX (see the list_tags input).
set -euo pipefail
source "$(dirname "$0")/common.sh"

TOOLCHAIN="$(echo "${CLANG_TOOLCHAIN:-AOSP}" | tr '[:upper:]' '[:lower:]')"
GF_CLANG_VERSION="${GF_CLANG_VERSION:-latest}"
TC_ROOT="${HOME}/toolchains"
CLANG_TAG=""

# ── helpers ────────────────────────────────────────────────────────────────

# Download <url>, extract, locate bin/clang and move that toolchain root to <dest>.
fetch_clang_archive() {
  local url="$1" dest="$2" tag="$3" tmp bin
  log_info "Downloading: ${url}"
  tmp=$(mktemp -d)
  wget -q -O "${tmp}/clang.tar" "${url}" || { rm -rf "${tmp}"; log_error "Download failed (wrong tag, or asset removed from Releases?)."; return 1; }
  mkdir -p "${tmp}/x"
  tar -xf "${tmp}/clang.tar" -C "${tmp}/x" || { rm -rf "${tmp}"; log_error "Extract failed (.tar.zst needs zstd)."; return 1; }
  bin=$(find "${tmp}/x" -maxdepth 5 -path '*/bin/clang' \( -type f -o -type l \) | head -n1)
  if [ -z "${bin}" ]; then
    log_error "bin/clang not found in archive. Top-level contents:"
    ls -la "${tmp}/x" | sed 's/^/    /'
    rm -rf "${tmp}"; return 1
  fi
  rm -rf "${dest}"; mkdir -p "$(dirname "${dest}")"
  mv "$(dirname "$(dirname "${bin}")")" "${dest}"
  echo "${tag}" > "${dest}/.gf_tag"
  rm -rf "${tmp}"
}

# Greenforce: "<tag>\t<clang major>\t<asset url>", newest first
GF_API="https://api.github.com/repos/greenforce-project/greenforce_clang/releases"
GF_FALLBACK_TAG="20072024"; GF_FALLBACK_MAJOR="19"
GF_FALLBACK_URL="https://github.com/greenforce-project/greenforce_clang/releases/download/20072024/greenforce-clang-19.0.0git-20072024.tar.zst"

gf_list() {
  local page out auth=()
  [ -n "${GITHUB_TOKEN:-}" ] && auth=(-H "Authorization: Bearer ${GITHUB_TOKEN}")
  for page in 1 2 3; do
    out=$(curl -fsSL "${auth[@]}" "${GF_API}?per_page=100&page=${page}" | python3 -c '
import sys, json, re
for r in json.load(sys.stdin):
    if r.get("draft"):
        continue
    for a in r.get("assets", []):
        n = a["name"]
        if not n.endswith((".tar.gz", ".tar.zst", ".tar.xz")):
            continue
        m = re.search(r"clang-(\d+)\.\d+\.\d+", n, re.I)
        print(r["tag_name"], m.group(1) if m else "?", a["browser_download_url"], sep="\t")
        break
') || break
    [ -z "${out}" ] && break
    printf '%s\n' "${out}"
  done
}

download_greenforce() {
  local list line tag major url
  list=$(gf_list || true)
  if [ -z "${list}" ]; then
    if [ "${GF_CLANG_VERSION}" = "latest" ]; then
      log_warn "Could not fetch the Greenforce release list; using fallback ${GF_FALLBACK_TAG} (clang ${GF_FALLBACK_MAJOR})."
      tag="${GF_FALLBACK_TAG}"; major="${GF_FALLBACK_MAJOR}"; url="${GF_FALLBACK_URL}"
    else
      log_error "Could not fetch the Greenforce release list (network / GitHub rate limit?)."; return 1
    fi
  else
    case "${GF_CLANG_VERSION}" in
      latest)            line=$(head -n1 <<<"${list}") ;;
      [0-9]|[0-9][0-9])  line=$(awk -F'\t' -v v="${GF_CLANG_VERSION}" '$2==v{print; exit}' <<<"${list}") ;;
      *)                 line=$(awk -F'\t' -v v="${GF_CLANG_VERSION}" '$1==v{print; exit}' <<<"${list}") ;;
    esac
    if [ -z "${line}" ]; then
      log_error "clang_version '${GF_CLANG_VERSION}' not found for Greenforce. Available majors:"
      awk -F'\t' '!seen[$2]++{printf "    clang %s\n",$2}' <<<"${list}"
      return 1
    fi
    IFS=$'\t' read -r tag major url <<<"${line}"
  fi
  log_info "Greenforce Clang ${major} (tag ${tag})"
  fetch_clang_archive "${url}" "${CLANG_DIR}" "${tag}"
}

download_zyc() {
  local raw="https://raw.githubusercontent.com/ZyCromerZ/Clang/main"
  local rel="https://github.com/ZyCromerZ/Clang/releases/download" url="" t
  case "${GF_CLANG_VERSION}" in
    latest|main)       url=$(curl -fsSL "${raw}/Clang-main-link.txt" | tr -d '[:space:]') ;;
    [0-9]|[0-9][0-9])  url=$(curl -fsSL "${raw}/Clang-${GF_CLANG_VERSION}-link.txt" | tr -d '[:space:]') ;;
    *)                 t="${GF_CLANG_VERSION%-release}"; url="${rel}/${t}-release/Clang-${t}.tar.gz" ;;
  esac
  [ -n "${url}" ] || { log_error "ZyC version '${GF_CLANG_VERSION}' not found. Use: latest | 10-16 | tag (e.g. 23.0.0git-20260130-release)."; return 1; }
  CLANG_TAG_NEW=$(basename "$(dirname "${url}")")
  log_info "ZyC Clang (tag ${CLANG_TAG_NEW})"
  fetch_clang_archive "${url}" "${CLANG_DIR}" "${CLANG_TAG_NEW}"
}

download_weebx() {
  local raw="https://raw.githubusercontent.com/XSans0/WeebX-Clang/main"
  local rel="https://github.com/XSans0/WeebX-Clang/releases/download" url="" tag
  case "${GF_CLANG_VERSION}" in
    latest)            url=$(curl -fsSL "${raw}/main/link.txt" | tr -d '[:space:]') ;;
    [0-9]|[0-9][0-9])  url=$(curl -fsSL "${raw}/release/${GF_CLANG_VERSION}.x/link.txt" | tr -d '[:space:]') ;;
    *)                 tag="${GF_CLANG_VERSION}"; url="${rel}/${tag}/${tag%-release}.tar.gz" ;;
  esac
  [ -n "${url}" ] || { log_error "WeebX version '${GF_CLANG_VERSION}' not found. Use: latest | 16 | 17 | 18 | 19 | tag (e.g. WeebX-Clang-19.1.5-release)."; return 1; }
  CLANG_TAG_NEW=$(basename "$(dirname "${url}")")
  log_info "WeebX Clang (tag ${CLANG_TAG_NEW})"
  fetch_clang_archive "${url}" "${CLANG_DIR}" "${CLANG_TAG_NEW}"
}

# ld.lld & friends often need libxml2.so.2 / libtinfo.so.5. If a differently-versioned
# library exists, symlink it into <clang>/lib; fail early if a binary still cannot run.
fix_clang_libs() {
  local b missing="" m base cand out
  export LD_LIBRARY_PATH="${CLANG_DIR}/lib:${LD_LIBRARY_PATH:-}"
  for b in ld.lld clang llvm-ar llvm-nm llvm-objcopy; do
    [ -x "${CLANG_DIR}/bin/${b}" ] || continue
    missing+=$'\n'$(ldd "${CLANG_DIR}/bin/${b}" 2>/dev/null | awk '/not found/{print $1}')
  done
  missing=$(printf '%s\n' "${missing}" | sed '/^$/d' | sort -u)
  [ -z "${missing}" ] && return 0
  log_warn "Missing toolchain libraries: $(echo "${missing}" | tr '\n' ' ')"
  if grep -q '^libxml2' <<<"${missing}"; then
    sudo apt-get install -y --no-install-recommends libxml2 >/dev/null 2>&1 \
      || sudo apt-get install -y --no-install-recommends libxml2-16 >/dev/null 2>&1 || true
  fi
  mkdir -p "${CLANG_DIR}/lib"
  for m in ${missing}; do
    ldconfig -p 2>/dev/null | grep -qF "${m} " && continue
    base="${m%%.so*}"
    cand=$(ldconfig -p 2>/dev/null | awk -v b="${base}.so" 'index($1,b)==1{print $NF}' | head -n1)
    [ -z "${cand}" ] && cand=$(ls /usr/lib/x86_64-linux-gnu/${base}.so.* /lib/x86_64-linux-gnu/${base}.so.* 2>/dev/null | head -n1 || true)
    if [ -n "${cand}" ]; then
      ln -sf "${cand}" "${CLANG_DIR}/lib/${m}"
      log_info "Symlink ${m} -> ${cand}"
    fi
  done
  for b in ld.lld clang; do
    [ -x "${CLANG_DIR}/bin/${b}" ] || continue
    if ! out=$("${CLANG_DIR}/bin/${b}" --version 2>&1); then
      log_error "${b} still fails to run:"; echo "${out}" | head -n3 | sed 's/^/    /'
      exit 1
    fi
  done
}

# ── toolchain selection ────────────────────────────────────────────────────
case "${TOOLCHAIN}" in
  aosp)
    echo "=== Using AOSP Clang ==="
    CLANG_DIR="${GITHUB_WORKSPACE}/clang"
    if [ ! -x "${CLANG_DIR}/bin/clang" ]; then
      log_error "AOSP Clang not found at ${CLANG_DIR}/bin"; exit 1
    fi
    ;;

  neutron)
    echo "=== Installing Neutron Clang ==="
    CLANG_DIR="${TC_ROOT}/neutron-clang"
    mkdir -p "${CLANG_DIR}"; cd "${CLANG_DIR}"
    if [ ! -x "${CLANG_DIR}/antman" ]; then
      curl -LO "https://raw.githubusercontent.com/Neutron-Toolchains/antman/main/antman"
      chmod +x antman
    fi
    ./antman -S
    [ -x "${CLANG_DIR}/bin/clang" ] || { log_error "Neutron Clang not found at ${CLANG_DIR}/bin"; exit 1; }
    ;;

  greenforce|zyc|weebx)
    CLANG_DIR="${TC_ROOT}/clang-${TOOLCHAIN}-${GF_CLANG_VERSION//\//_}"
    echo "=== Installing ${TOOLCHAIN} Clang (${GF_CLANG_VERSION}) ==="
    CLANG_TAG_NEW=""
    case "${TOOLCHAIN}" in
      greenforce) download_greenforce ;;
      zyc)        download_zyc ;;
      weebx)      download_weebx ;;
    esac || { log_error "Failed to prepare ${TOOLCHAIN} Clang."; exit 1; }
    [ -x "${CLANG_DIR}/bin/clang" ] || { log_error "clang not found in ${CLANG_DIR}/bin."; exit 1; }
    ;;

  *)
    log_error "Unknown Clang toolchain: ${TOOLCHAIN}"; exit 1 ;;
esac

CLANG_PATH="${CLANG_DIR}/bin"
[ -f "${CLANG_DIR}/.gf_tag" ] && CLANG_TAG="$(cat "${CLANG_DIR}/.gf_tag")"
[ "${TOOLCHAIN}" != "aosp" ] && fix_clang_libs

echo "Selected toolchain: ${TOOLCHAIN}"
echo "Clang path: ${CLANG_PATH}"

{
  echo "CLANG_PATH=${CLANG_PATH}"
  echo "CLANG_DIR=${CLANG_DIR}"
  echo "CLANG_TAG=${CLANG_TAG}"
} >> "${GITHUB_ENV}"
echo "${CLANG_PATH}" >> "${GITHUB_PATH}"

"${CLANG_PATH}/clang" --version
