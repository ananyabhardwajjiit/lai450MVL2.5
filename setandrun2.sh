#!/usr/bin/env bash
# setandrun2.sh - lfm-vision SOURCE BUILD installer
#
# What it installs:
#   - llama.cpp BUILT FROM SOURCE with -DGGML_NATIVE=ON (CPU-tuned for YOUR chip)
#   - Liquid AI 450M vision model
#   - Status page on :80
#   - OpenWebUI on :8080 (optional)
#
# Why build from source instead of using the prebuilt:
#   - Prebuilt binaries are generic. Building with -DGGML_NATIVE compiles in
#     instructions your specific CPU supports (AVX2, AVX-512, AMX, FMA, etc.)
#     which can give a meaningful speedup for the 450M model.
#   - You get the absolute latest llama.cpp the moment it's tagged.
#   - You're not trusting a prebuilt tarball from the project.
#
# Trade-off: 5-10 minute compile time, needs build-essential + cmake.
#
# For a faster install (just prebuilt), see setandrunall.sh.
#
# Usage:
#   ./setandrun2.sh
#   ./setandrun2.sh --with-openwebui
#   ./setandrun2.sh --update
#   ./setandrun2.sh --uninstall
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
# Preset: build = compile llama.cpp for best perf
# =============================================================================
PRESET_NAME="build"
PRESET_TAGLINE="Compiles llama.cpp from source with native CPU flags. 5-10 min build."
PRESET_STATUS_PAGE="true"
PRESET_OPENWEBUI="false"

# Build from source. The result lands in /opt/lfm-vision/src/llama.cpp/build/bin/llama-server
LLAMA_SRC_DIR="$LFM_INSTALL_ROOT/src/llama.cpp"

install_llama_strategy() {
  local release="$1" arch="$2"
  log_step "Building llama.cpp ${release} from source for ${arch}"
  log_warn "This will take 5-10 minutes depending on your CPU."

  # Build deps (in addition to base install_dependencies)
  lfm_sudo apt-get install -y --no-install-recommends \
    build-essential cmake git pkg-config libcurl4-openssl-dev

  lfm_sudo rm -rf "$LLAMA_SRC_DIR"
  lfm_sudo mkdir -p "$(dirname "$LLAMA_SRC_DIR")"
  lfm_sudo git clone https://github.com/ggml-org/llama.cpp.git "$LLAMA_SRC_DIR"
  lfm_sudo chown -R "$(id -u):$(id -g)" "$LLAMA_SRC_DIR"

  (
    cd "$LLAMA_SRC_DIR"
    git fetch --tags --quiet
    if git rev-parse "$release" >/dev/null 2>&1; then
      git checkout "$release"
    else
      log_warn "Release $release not found in repo; staying on default branch"
    fi
    log_info "Building $(git describe --tags --always 2>/dev/null || echo 'HEAD')"
  )

  cmake -S "$LLAMA_SRC_DIR" -B "$LLAMA_SRC_DIR/build" \
    -DCMAKE_BUILD_TYPE=Release \
    -DGGML_NATIVE=ON \
    -DCMAKE_INSTALL_PREFIX="$LFM_BIN_DIR" \
    >/dev/null
  cmake --build "$LLAMA_SRC_DIR/build" -j"$(lfm_detect_cpu_threads)"

  local bin="$LLAMA_SRC_DIR/build/bin/llama-server"
  [ -x "$bin" ] || die "llama-server binary not produced at $bin"

  # Stage the binary + shared libs into the canonical install dir
  lfm_sudo rm -rf "$LFM_BIN_DIR"
  lfm_sudo mkdir -p "$LFM_BIN_DIR"
  lfm_sudo install -m 755 "$bin" "$LFM_BIN_DIR/llama-server"
  # Copy any required shared libs alongside the binary
  lfm_sudo cp -a "$LLAMA_SRC_DIR/build/bin/." "$LFM_BIN_DIR/" 2>/dev/null || true

  log_ok "Built and staged: $LFM_BIN_DIR/llama-server"
  LFM_LLAMA_BIN="$LFM_BIN_DIR/llama-server"
  LFM_LLAMA_RELEASE="$release"
}

main_dispatch "$@"
