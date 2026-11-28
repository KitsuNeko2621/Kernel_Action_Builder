#!/usr/bin/env bash
# Shared helpers. Source from other scripts:  source "$(dirname "$0")/common.sh"

RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'; BLUE='\033[0;34m'; NC='\033[0m'

BUILD_LOG="${BUILD_LOG:-${GITHUB_WORKSPACE:-$PWD}/logs/build.log}"
mkdir -p "$(dirname "${BUILD_LOG}")"

_log_file()   { echo "$*" >> "${BUILD_LOG}"; return 0; }
log_info()    { echo -e "${BLUE}[INFO]${NC} $1";   _log_file "[INFO] $1"; }
log_success() { echo -e "${GREEN}[OK]${NC} $1";    _log_file "[OK] $1"; }
log_warn()    { echo -e "${YELLOW}[WARN]${NC} $1"; _log_file "[WARN] $1"; echo "::warning::$1"; }
log_error()   { echo -e "${RED}[ERROR]${NC} $1";   _log_file "[ERROR] $1"; echo "::error::$1"; }

# Append KEY=VALUE to the job environment (no-op outside GitHub Actions)
set_env() { [ -n "${GITHUB_ENV:-}" ] && echo "$1=$2" >> "${GITHUB_ENV}"; export "$1=$2"; }
