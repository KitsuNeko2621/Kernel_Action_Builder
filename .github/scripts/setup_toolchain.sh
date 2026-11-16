#!/usr/bin/env bash
# Toolchain: greenforce (versi: latest | major | tag) atau neutron.
set -euo pipefail

TOOLCHAIN="${CLANG_TOOLCHAIN_INPUT:-greenforce}"
GF_VERSION="${INPUT_CLANG_VERSION:-latest}"
GF_VERSION="${GF_VERSION:-latest}"

GF_API="https://api.github.com/repos/greenforce-project/greenforce_clang/releases"
# Cadangan kalau API GitHub gagal (hanya dipakai untuk "latest"): rilis yang dulu dipakai workflow GC17
GF_FALLBACK_TAG="24122023"
GF_FALLBACK_MAJOR="17"
GF_FALLBACK_URL="https://github.com/greenforce-project/greenforce_clang/releases/download/24122023/greenforce-clang-17.0.6-24122023-0137.tar.zst"

# Output: <tag> TAB <major> TAB <url>, rilis terbaru di baris pertama
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
        m = re.search(r"clang-(\d+)\.\d+\.\d+", n)
        print(r["tag_name"], m.group(1) if m else "?", a["browser_download_url"], sep="\t")
        break
') || break
    [ -z "${out}" ] && break
    printf '%s\n' "${out}"
  done
}

setup_greenforce() {
  local list line GF_TAG GF_MAJOR GF_URL
  list=$(gf_list || true)
  if [ -z "${list}" ]; then
    if [ "${GF_VERSION}" = "latest" ]; then
      echo "::warning::Daftar rilis Greenforce gagal diambil, pakai cadangan ${GF_FALLBACK_TAG} (clang ${GF_FALLBACK_MAJOR})."
      GF_TAG="${GF_FALLBACK_TAG}"; GF_MAJOR="${GF_FALLBACK_MAJOR}"; GF_URL="${GF_FALLBACK_URL}"
    else
      echo "::error::Gagal mengambil daftar rilis Greenforce Clang (jaringan / rate limit)."; exit 1
    fi
  else
    case "${GF_VERSION}" in
      latest)           line=$(head -n1 <<<"${list}") ;;
      [0-9]|[0-9][0-9]) line=$(awk -F'\t' -v v="${GF_VERSION}" '$2==v{print; exit}' <<<"${list}") ;;
      *)                line=$(awk -F'\t' -v v="${GF_VERSION}" '$1==v{print; exit}' <<<"${list}") ;;
    esac
    if [ -z "${line}" ]; then
      echo "::error::clang_version '${GF_VERSION}' tidak ditemukan. Versi major yang ada:"
      awk -F'\t' '!seen[$2]++{printf "    clang %s (tag %s)\n",$2,$1}' <<<"${list}"
      exit 1
    fi
    IFS=$'\t' read -r GF_TAG GF_MAJOR GF_URL <<<"${line}"
  fi

  echo "=== Greenforce Clang ${GF_MAJOR} (tag ${GF_TAG}) ==="
  local dest="${HOME}/toolchains/clang-greenforce-${GF_TAG}" tmp
  if [ ! -x "${dest}/bin/clang" ]; then
    tmp=$(mktemp -d)
    wget -q -O "${tmp}/clang.tar" "${GF_URL}"
    mkdir -p "${tmp}/x"
    tar -xf "${tmp}/clang.tar" -C "${tmp}/x"
    local bin; bin=$(find "${tmp}/x" -maxdepth 5 -path '*/bin/clang' \( -type f -o -type l \) | head -n1)
    [ -n "${bin}" ] || { echo "::error::bin/clang tidak ada di arsip Greenforce."; exit 1; }
    rm -rf "${dest}"; mkdir -p "$(dirname "${dest}")"
    mv "$(dirname "$(dirname "${bin}")")" "${dest}"
    rm -rf "${tmp}"
  fi
  CLANG_PATH="${dest}/bin"
  CLANG_TAG="${GF_TAG}"
}

setup_neutron() {
  echo "=== Neutron Clang ==="
  local dir="${HOME}/toolchains/neutron-clang"
  mkdir -p "${dir}"; cd "${dir}"
  if [ ! -x antman ]; then
    curl -fsSLO "https://raw.githubusercontent.com/Neutron-Toolchains/antman/main/antman"
    chmod +x antman
  fi
  ./antman -S
  CLANG_PATH="${dir}/bin"
  CLANG_TAG="latest"
}

case "${TOOLCHAIN}" in
  greenforce) setup_greenforce ;;
  neutron)    setup_neutron ;;
  *) echo "::error::clang_toolchain tidak dikenal: ${TOOLCHAIN}"; exit 1 ;;
esac

[ -x "${CLANG_PATH}/clang" ] || { echo "::error::clang tidak ditemukan di ${CLANG_PATH}"; exit 1; }

{
  echo "CLANG_TOOLCHAIN=${TOOLCHAIN}"
  echo "CLANG_TAG=${CLANG_TAG}"
  echo "CLANG_PATH=${CLANG_PATH}"
} >> "${GITHUB_ENV}"
echo "${CLANG_PATH}" >> "${GITHUB_PATH}"

"${CLANG_PATH}/clang" --version | head -n1
echo "Toolchain: ${TOOLCHAIN} | tag/versi: ${CLANG_TAG}"
