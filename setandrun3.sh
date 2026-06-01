#!/usr/bin/env bash
# setandrun3.sh - lfm-vision CUSTOM BINARY installer
#
# What it installs:
#   - llama-server binary from THIS PROJECT's own release (not upstream)
#   - Liquid AI 450M vision model
#   - Status page on :80
#   - OpenWebUI on :8080 (optional)
#
# Why use a custom release instead of upstream:
#   - The project's binary is built with flags optimized for the LFM2.5-VL
#     model specifically (e.g. specific CUDA arches, MKL, custom quantization).
#   - Faster install (no 5-10 min compile) and consistent behavior across hosts.
#
# Trade-off: depends on the project maintaining a release; if the release is
# stale, the upstream install (setandrunall.sh) is safer.
#
# For the upstream prebuilt, see setandrunall.sh.
# For building from source, see setandrun2.sh.
#
# Usage:
#   ./setandrun3.sh
#   ./setandrun3.sh --with-openwebui
#   ./setandrun3.sh --update
#   ./setandrun3.sh --uninstall
#
set -Eeuo pipefail

case "${BASH_SOURCE[0]:-}" in
  /dev/stdin|"") SCRIPT_DIR="" ;;
  *)            SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)" ;;
esac
LFM_REPO_BASE="https://raw.githubusercontent.com/ananyabhardwajjiit/lai450MVL2.5/main"
LFM_ENTRY_DIR="${SCRIPT_DIR:-}"

if [ -n "$SCRIPT_DIR" ] && [ -f "$SCRIPT_DIR/lib/common.sh" ]; then
  source "$SCRIPT_DIR/lib/common.sh"
  source "$SCRIPT_DIR/lib/install.sh"
else
  # curl|bash path: fetch the libs from the repo using plain curl/wget.
  _lib_dir="$(mktemp -d)"
  # shellcheck disable=SC2064
  trap "rm -rf '$_lib_dir'" EXIT
  printf '[INFO] Downloading shared library (curl|bash mode)\n' >&2
  for f in common.sh install.sh; do
    if command -v curl >/dev/null 2>&1; then
      curl -fsSL -o "$_lib_dir/$f" "$LFM_REPO_BASE/lib/$f" \
        || { echo "FATAL: could not fetch lib/$f from $LFM_REPO_BASE" >&2; exit 1; }
    elif command -v wget >/dev/null 2>&1; then
      wget -q -O "$_lib_dir/$f" "$LFM_REPO_BASE/lib/$f" \
        || { echo "FATAL: could not fetch lib/$f from $LFM_REPO_BASE" >&2; exit 1; }
    else
      echo "FATAL: curl or wget required" >&2; exit 1
    fi
  done
  source "$_lib_dir/common.sh"
  source "$_lib_dir/install.sh"
  LFM_ENTRY_DIR=""
fi

# =============================================================================
# Preset: prebuilt = project's own optimized binary
# =============================================================================
PRESET_NAME="prebuilt"
PRESET_TAGLINE="Uses the project's own prebuilt llama-server release (faster, model-tuned)."
PRESET_STATUS_PAGE="true"
PRESET_OPENWEBUI="false"

# Map arch to the project's release asset name
CUSTOM_RELEASE_BASE="https://github.com/ananyabhardwajjiit/lai450MVL2.5/releases/download/v1.0"
CUSTOM_ASSET_NAME="llama-server-bin.tar.gz"

install_llama_strategy() {
  local release="$1" arch="$2"
  local url="${CUSTOM_RELEASE_BASE}/${CUSTOM_ASSET_NAME}"
  log_step "Downloading custom-built llama-server from project release"
  log_info "URL: $url"
  log_warn "(If this URL is stale, the upstream prebuilt install is safer.)"

  local tmpdir
  tmpdir="$(mktemp -d)"
  # shellcheck disable=SC2064
  trap "rm -rf '$tmpdir'" RETURN

  lfm_download "$url" "$tmpdir/llama.tar.gz"
  lfm_sudo rm -rf "$LFM_BIN_DIR"
  lfm_sudo mkdir -p "$LFM_BIN_DIR"
  lfm_sudo tar -xzf "$tmpdir/llama.tar.gz" -C "$LFM_BIN_DIR"

  local bin="$LFM_BIN_DIR/llama-server"
  [ -x "$bin" ] || die "llama-server binary not found at $bin after extract"
  log_ok "llama-server ready: $bin"
  LFM_LLAMA_BIN="$bin"
  LFM_LLAMA_RELEASE="custom-v1.0"
}

main_dispatch "$@"
