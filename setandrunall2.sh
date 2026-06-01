#!/usr/bin/env bash
# setandrunall2.sh - lfm-vision MINIMAL installer
#
# What it installs:
#   - llama.cpp (latest Ubuntu prebuilt for your arch)
#   - Liquid AI 450M vision model
#   - llama-server as a systemd service on :8000
#   - Nothing else. No status page, no OpenWebUI.
#
# Use this when:
#   - You're running lfm-vision headless on a server with no public web UI
#   - You want the smallest possible dependency footprint
#   - You're integrating lfm-vision into another system (Home Assistant, n8n, etc.)
#
# For the full product (status page + optional chat UI), see setandrunall.sh.
#
# Usage:
#   ./setandrunall2.sh
#   ./setandrunall2.sh --update
#   ./setandrunall2.sh --uninstall
#   curl -fsSL .../setandrunall2.sh | bash
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
# Preset: minimal = API only, no UI
# =============================================================================
PRESET_NAME="minimal"
PRESET_TAGLINE="API only: prebuilt llama.cpp + systemd service. No status page, no chat UI."
PRESET_STATUS_PAGE="false"
PRESET_OPENWEBUI="false"

install_llama_strategy() {
  local release="$1" arch="$2"
  local url
  url="$(lfm_llama_binary_url "$release" "$arch")"
  log_step "Installing llama.cpp ${release} (${arch} prebuilt)"
  log_info "URL: $url"

  local tmpdir
  tmpdir="$(mktemp -d)"
  # shellcheck disable=SC2064
  trap "rm -rf '$tmpdir'" RETURN

  lfm_download "$url" "$tmpdir/llama.tar.gz"
  lfm_sudo rm -rf "$LFM_BIN_DIR"
  lfm_sudo mkdir -p "$LFM_BIN_DIR"
  lfm_sudo tar -xzf "$tmpdir/llama.tar.gz" -C "$LFM_BIN_DIR" --strip-components=1

  local bin
  bin="$(find "$LFM_BIN_DIR" -name 'llama-server' -type f -executable | head -1)"
  [ -z "$bin" ] && bin="$(find "$LFM_BIN_DIR" -name 'llama-server' -type f | head -1)"
  [ -z "$bin" ] && die "llama-server binary not found after extract"
  lfm_sudo chmod +x "$bin"
  log_ok "llama-server ready: $bin"
  LFM_LLAMA_BIN="$bin"
  LFM_LLAMA_RELEASE="$release"
}

main_dispatch "$@"
