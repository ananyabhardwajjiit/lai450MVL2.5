#!/usr/bin/env bash
# setandrunall.sh - lfm-vision MAIN installer
#
# What it installs:
#   - llama.cpp (latest Ubuntu prebuilt binary for your arch, x64 or arm64)
#   - Liquid AI 450M vision model from Hugging Face
#   - Status landing page on :80
#   - OpenWebUI on :8080 (optional, --with-openwebui)
#   - All as proper systemd services
#
# This is the full "product" install. For minimal/headless, see setandrunall2.sh.
# For building llama.cpp from source, see setandrun2.sh.
# For using a prebuilt binary from the project's own release, see setandrun3.sh.
#
# Usage:
#   ./setandrunall.sh                          # default
#   ./setandrunall.sh --with-openwebui         # + chat UI
#   ./setandrunall.sh --update                 # pull latest llama.cpp
#   ./setandrunall.sh --uninstall              # remove everything
#   curl -fsSL .../setandrunall.sh | bash -s -- --with-openwebui
#
set -Eeuo pipefail

# =============================================================================
# Shared lib: prefer sibling file, else fetch from repo, else embed minimal
# =============================================================================
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
  # curl|bash path: fetch the libs from the repo into a temp dir using
  # plain curl/wget (lfm_download lives IN the lib, so we can't use it yet).
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
# Preset: main = full product install
# =============================================================================
PRESET_NAME="main"
PRESET_TAGLINE="Full product: prebuilt llama.cpp + status page + optional OpenWebUI"
PRESET_STATUS_PAGE="true"
PRESET_OPENWEBUI="false"

# Prebuilt binary from official llama.cpp releases
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
