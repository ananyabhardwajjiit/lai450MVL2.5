#!/usr/bin/env bash
# lib/common.sh - Shared functions for lfm-vision installers
# This file is sourced by the install scripts. When invoked via curl | bash
# the same content is embedded inline at the top of the script.
#
# Conventions:
#   - All paths are absolute, no hardcoded /home/<user>
#   - All output goes through log_* functions (TUI-friendly, color-aware)
#   - Idempotent: re-running with same args should be safe
#   - Privilege: scripts detect if root, use sudo only when needed

set -Eeuo pipefail
IFS=$'\n\t'

# -----------------------------------------------------------------------------
# Paths (single source of truth)
# -----------------------------------------------------------------------------
#: ${LFM_INSTALL_ROOT:=/opt/lfm-vision}
#: ${LFM_DATA_ROOT:=/var/lib/lfm-vision}
#: ${LFM_CONFIG_DIR:=/etc/lfm-vision}
#: ${LFM_LOG_DIR:=/var/log/lfm-vision}
#: ${LFM_MODEL_DIR:=/var/lib/lfm-vision/models}
#: ${LFM_BIN_DIR:=/opt/lfm-vision/bin}
#: ${LFM_STATUS_DIR:=/opt/lfm-vision/status}

LFM_INSTALL_ROOT="${LFM_INSTALL_ROOT:-/opt/lfm-vision}"
LFM_DATA_ROOT="${LFM_DATA_ROOT:-/var/lib/lfm-vision}"
LFM_CONFIG_DIR="${LFM_CONFIG_DIR:-/etc/lfm-vision}"
LFM_LOG_DIR="${LFM_LOG_DIR:-/var/log/lfm-vision}"
LFM_MODEL_DIR="${LFM_MODEL_DIR:-${LFM_DATA_ROOT}/models}"
LFM_BIN_DIR="${LFM_BIN_DIR:-${LFM_INSTALL_ROOT}/bin}"
LFM_STATUS_DIR="${LFM_STATUS_DIR:-${LFM_INSTALL_ROOT}/status}"

LFM_CONFIG_FILE="${LFM_CONFIG_DIR}/config.yaml"
LFM_STATE_FILE="${LFM_DATA_ROOT}/state.json"
LFM_VERSION_FILE="${LFM_DATA_ROOT}/version"

# Service names
LFM_SERVICE_API="lfm-vision-api"
LFM_SERVICE_STATUS="lfm-vision-status"
LFM_SERVICE_WEBUI="lfm-vision-webui"

# Default ports
LFM_API_PORT="${LFM_API_PORT:-8000}"
LFM_STATUS_PORT="${LFM_STATUS_PORT:-80}"
LFM_WEBUI_PORT="${LFM_WEBUI_PORT:-8080}"

# -----------------------------------------------------------------------------
# Colors / logging
# -----------------------------------------------------------------------------
if [ -t 1 ]; then
  _C_RESET=$'\033[0m'
  _C_BOLD=$'\033[1m'
  _C_DIM=$'\033[2m'
  _C_RED=$'\033[31m'
  _C_GREEN=$'\033[32m'
  _C_YELLOW=$'\033[33m'
  _C_BLUE=$'\033[34m'
  _C_MAGENTA=$'\033[35m'
  _C_CYAN=$'\033[36m'
else
  _C_RESET=""; _C_BOLD=""; _C_DIM=""
  _C_RED=""; _C_GREEN=""; _C_YELLOW=""
  _C_BLUE=""; _C_MAGENTA=""; _C_CYAN=""
fi

_log() {
  local level="$1"; shift
  local color="$_C_RESET"
  case "$level" in
    INFO)  color="$_C_CYAN" ;;
    OK)    color="$_C_GREEN" ;;
    WARN)  color="$_C_YELLOW" ;;
    ERR)   color="$_C_RED" ;;
    STEP)  color="$_C_BOLD$_C_MAGENTA" ;;
  esac
  printf '%s[%s]%s %s\n' "$color" "$level" "$_C_RESET" "$*" >&2
}

log_info()  { _log INFO  "$@"; }
log_ok()    { _log OK    "$@"; }
log_warn()  { _log WARN  "$@" >&2; }
log_error() { _log ERR   "$@" >&2; }
log_step()  { _log STEP  "==> $*"; }

# Fatal error with optional hint
die() {
  log_error "$@"
  exit 1
}

# Run a command, or print it in dry-run mode
run() {
  if [ "${LFM_DRY_RUN:-0}" = "1" ]; then
    printf '  %s$ %s%s\n' "$_C_DIM" "$*" "$_C_RESET" >&2
  else
    "$@"
  fi
}

# -----------------------------------------------------------------------------
# Privilege handling - no more hardcoded /home/ubuntu
# -----------------------------------------------------------------------------
# Detects the actual user even when run with sudo
lfm_detect_user() {
  if [ -n "${SUDO_USER:-}" ]; then
    echo "$SUDO_USER"
  elif [ -n "${USER:-}" ] && [ "$USER" != "root" ]; then
    echo "$USER"
  else
    # Try to find a non-root user with a login shell (best-effort)
    awk -F: '$3 >= 1000 && $3 < 65534 && $7 ~ /sh$/ {print $1; exit}' /etc/passwd
  fi
}

LFM_USER="$(lfm_detect_user)"
LFM_USER_HOME="$(getent passwd "$LFM_USER" 2>/dev/null | cut -d: -f6 || echo "/root")"

# Run command as the detected user (or root)
lfm_as_user() {
  if [ "$(id -un)" = "$LFM_USER" ]; then
    "$@"
  elif [ -n "$LFM_USER" ] && [ "$LFM_USER" != "root" ]; then
    sudo -u "$LFM_USER" -H "$@"
  else
    "$@"
  fi
}

# Run command with sudo only if not already root
lfm_sudo() {
  if [ "$(id -u)" = "0" ]; then
    "$@"
  else
    sudo "$@"
  fi
}

# -----------------------------------------------------------------------------
# Architecture & OS detection
# -----------------------------------------------------------------------------
lfm_detect_arch() {
  local m
  m="$(uname -m)"
  case "$m" in
    x86_64|amd64)  echo "x64" ;;
    aarch64|arm64) echo "arm64" ;;
    armv7l|armv7)  echo "armv7" ;;
    *)             die "Unsupported architecture: $m" ;;
  esac
}

lfm_detect_os() {
  if [ -f /etc/os-release ]; then
    . /etc/os-release
    echo "${ID:-linux}"
  else
    echo "linux"
  fi
}

# -----------------------------------------------------------------------------
# Hardware detection - CPU, RAM, GPU
# -----------------------------------------------------------------------------
lfm_detect_cpu_threads() {
  nproc 2>/dev/null || echo "1"
}

lfm_detect_ram_mb() {
  awk '/MemTotal/ {print int($2/1024)}' /proc/meminfo
}

lfm_detect_gpu() {
  # Returns one of: nvidia | amd | intel | apple | none
  if command -v nvidia-smi >/dev/null 2>&1 && nvidia-smi >/dev/null 2>&1; then
    echo "nvidia"; return
  fi
  if command -v rocm-smi >/dev/null 2>&1 && rocm-smi >/dev/null 2>&1; then
    echo "amd"; return
  fi
  # Intel GPU via intel_gpu_top (less reliable as detection)
  if lspci 2>/dev/null | grep -qi 'vga.*intel'; then
    if lspci 2>/dev/null | grep -qi 'vga.*apple'; then
      echo "apple"; return
    fi
    # Don't claim intel GPU acceleration unless we know llama.cpp supports it
    # for the user's specific model. Treat as CPU.
    echo "none"; return
  fi
  echo "none"
}

lfm_detect_avx2() {
  # Check /proc/cpuinfo for AVX2 support
  grep -q -E '^flags.*\bavx2\b' /proc/cpuinfo 2>/dev/null && echo "yes" || echo "no"
}

# Auto-tune parameters based on hardware.
# Outputs suggested: --threads, --ctx, --parallel, --batch
lfm_autotune() {
  local threads ram_mb gpu
  threads="$(lfm_detect_cpu_threads)"
  ram_mb="$(lfm_detect_ram_mb)"
  gpu="$(lfm_detect_gpu)"

  local llama_threads batch_threads parallel ctx_size batch_size
  if [ "$threads" -ge 8 ]; then
    llama_threads=$(( threads - 2 ))
    batch_threads=4
    parallel=4
  elif [ "$threads" -ge 4 ]; then
    llama_threads=3
    batch_threads=2
    parallel=2
  else
    llama_threads=2
    batch_threads=1
    parallel=1
  fi

  # Context size based on RAM (rough heuristic for 450M model; ~700MB working set)
  if [ "$ram_mb" -ge 8192 ]; then
    ctx_size=8192
  elif [ "$ram_mb" -ge 4096 ]; then
    ctx_size=4096
  else
    ctx_size=2048
  fi

  if [ "$gpu" = "nvidia" ]; then
    # Offload everything, fewer CPU threads needed
    llama_threads=2
    parallel=4
  fi

  cat <<EOF
threads=$llama_threads
batch_threads=$batch_threads
parallel=$parallel
ctx_size=$ctx_size
batch_size=1024
ubatch_size=512
gpu=$gpu
ram_mb=$ram_mb
cpu_threads=$threads
EOF
}

# -----------------------------------------------------------------------------
# Network helpers
# -----------------------------------------------------------------------------
# Fetch URL to stdout. Uses curl if available, else wget.
lfm_fetch() {
  local url="$1"
  if command -v curl >/dev/null 2>&1; then
    curl -fsSL --retry 3 --retry-delay 2 "$url"
  elif command -v wget >/dev/null 2>&1; then
    wget -qO- --tries=3 --timeout=30 "$url"
  else
    die "Need curl or wget to fetch $url"
  fi
}

# Download file with resume, retry, and progress
lfm_download() {
  local url="$1" out="$2"
  local dir
  dir="$(dirname "$out")"
  mkdir -p "$dir"

  if [ -f "$out" ] && [ -s "$out" ]; then
    log_info "✔ $out already exists, skipping"
    return 0
  fi

  log_info "⬇ Downloading $out"
  if command -v curl >/dev/null 2>&1; then
    curl -fL --retry 3 --retry-delay 2 --connect-timeout 15 -o "$out.part" "$url" \
      && mv "$out.part" "$out" \
      || { rm -f "$out.part"; die "Download failed: $url"; }
  else
    wget --tries=3 --timeout=30 --continue -O "$out.part" "$url" \
      && mv "$out.part" "$out" \
      || { rm -f "$out.part"; die "Download failed: $url"; }
  fi

  if [ ! -s "$out" ]; then
    rm -f "$out"
    die "Download produced empty file: $out"
  fi
}

# -----------------------------------------------------------------------------
# llama.cpp release detection
# -----------------------------------------------------------------------------
# Get the latest llama.cpp release tag from GitHub API.
# Returns just the tag, e.g. "b8152".
lfm_latest_llama_release() {
  local api="https://api.github.com/repos/ggml-org/llama.cpp/releases/latest"
  local body
  body="$(lfm_fetch "$api" 2>/dev/null || true)"
  if [ -z "$body" ]; then
    log_warn "GitHub API unreachable; falling back to known-good release b8152"
    echo "b8152"
    return
  fi
  # Extract tag_name from JSON
  local tag
  tag="$(printf '%s' "$body" | grep -oE '"tag_name"[[:space:]]*:[[:space:]]*"[^"]+"' \
         | head -1 | sed -E 's/.*"([^"]+)"/\1/')"
  if [ -z "$tag" ]; then
    log_warn "Could not parse latest release; falling back to b8152"
    echo "b8152"
    return
  fi
  echo "$tag"
}

# Build the binary download URL for a given release + arch
lfm_llama_binary_url() {
  local release="$1" arch="$2"
  case "$arch" in
    x64)   echo "https://github.com/ggml-org/llama.cpp/releases/download/${release}/llama-${release}-bin-ubuntu-x64.tar.gz" ;;
    arm64) echo "https://github.com/ggml-org/llama.cpp/releases/download/${release}/llama-${release}-bin-ubuntu-arm64.tar.gz" ;;
    *)     die "No prebuilt binary for arch: $arch" ;;
  esac
}

# -----------------------------------------------------------------------------
# Model catalog
# -----------------------------------------------------------------------------
# Format: model_id|hf_repo|model_gguf|mmproj_gguf|description
# Add new models here as they become available.
LFM_MODEL_CATALOG=(
  "450m|LiquidAI/LFM2.5-VL-450M-GGUF|LFM2.5-VL-450M-F16.gguf|mmproj-LFM2.5-VL-450m-F16.gguf|LFM2.5-VL 450M - the original tiny vision model"
)

# Look up a model by id. Sets globals: LFM_MODEL_REPO, LFM_MODEL_FILE, LFM_MMPROJ_FILE
lfm_lookup_model() {
  local id="$1"
  for entry in "${LFM_MODEL_CATALOG[@]}"; do
    local eid repo model mmproj desc
    IFS='|' read -r eid repo model mmproj desc <<< "$entry"
    if [ "$eid" = "$id" ]; then
      LFM_MODEL_REPO="$repo"
      LFM_MODEL_FILE="$model"
      LFM_MMPROJ_FILE="$mmproj"
      LFM_MODEL_DESC="$desc"
      return 0
    fi
  done
  return 1
}

lfm_list_models() {
  for entry in "${LFM_MODEL_CATALOG[@]}"; do
    local eid desc
    IFS='|' read -r eid _ _ _ desc <<< "$entry"
    printf '  %s%-8s%s  %s\n' "$_C_BOLD" "$eid" "$_C_RESET" "$desc"
  done
}

lfm_model_url()    { echo "https://huggingface.co/${LFM_MODEL_REPO}/resolve/main/${LFM_MODEL_FILE}"; }
lfm_mmproj_url()   { echo "https://huggingface.co/${LFM_MODEL_REPO}/resolve/main/${LFM_MMPROJ_FILE}"; }

# -----------------------------------------------------------------------------
# Config file handling (YAML subset, no external deps)
# -----------------------------------------------------------------------------
# We don't need a full YAML parser. Our config is flat key: value, with # comments.
# This keeps the script self-contained (no yq/python dep required for install).
LFM_CONFIG_DEFAULTS=(
  "model: 450m"
  "api_port: 8000"
  "status_port: 80"
  "webui_port: 8080"
  "with_openwebui: false"
  "with_status_page: true"
  "context_size: auto"
  "threads: auto"
  "parallel: auto"
  "install_dir: /opt/lfm-vision"
  "data_dir: /var/lib/lfm-vision"
  "log_level: info"
)

lfm_default_config() {
  local out="# lfm-vision configuration\n# Generated by the installer. Edit and run install.sh to re-apply.\n\n"
  out+="model: 450m\n"
  out+="api_port: 8000\n"
  out+="status_port: 80\n"
  out+="webui_port: 8080\n"
  out+="with_openwebui: false\n"
  out+="with_status_page: true\n"
  out+="context_size: auto\n"
  out+="threads: auto\n"
  out+="parallel: auto\n"
  out+="install_dir: /opt/lfm-vision\n"
  out+="data_dir: /var/lib/lfm-vision\n"
  printf '%b' "$out"
}

# Read a key from the config file. Empty string if not present.
lfm_config_get() {
  local key="$1" file="${2:-$LFM_CONFIG_FILE}"
  [ -f "$file" ] || return 0
  awk -F: -v k="$key" '
    /^[[:space:]]*#/ {next}
    /^[[:space:]]*$/ {next}
    $1 ~ "^[[:space:]]*"k"[[:space:]]*$" {
      sub(/^[^:]*:[[:space:]]*/, "");
      sub(/[[:space:]]*#.*$/, "");
      print;
      exit
    }
  ' "$file"
}

# Write the default config (only if missing)
lfm_config_init() {
  if [ ! -f "$LFM_CONFIG_FILE" ]; then
    lfm_sudo mkdir -p "$LFM_CONFIG_DIR"
    lfm_default_config | lfm_sudo tee "$LFM_CONFIG_FILE" >/dev/null
    lfm_sudo chmod 644 "$LFM_CONFIG_FILE"
    log_ok "Wrote config: $LFM_CONFIG_FILE"
  fi
}

# Resolve "auto" values using autotune. Outputs key=value pairs we eval.
lfm_resolve_autos() {
  local tune
  tune="$(lfm_autotune)"
  eval "$tune"  # threads, batch_threads, parallel, ctx_size, gpu, ram_mb, cpu_threads

  [ "${LFM_CFG_CTX:-}" = "auto" ] || [ -z "${LFM_CFG_CTX:-}" ] && LFM_CFG_CTX="$ctx_size"
  [ "${LFM_CFG_THREADS:-}" = "auto" ] || [ -z "${LFM_CFG_THREADS:-}" ] && LFM_CFG_THREADS="$llama_threads"
  [ "${LFM_CFG_PARALLEL:-}" = "auto" ] || [ -z "${LFM_CFG_PARALLEL:-}" ] && LFM_CFG_PARALLEL="$parallel"
  LFM_CFG_BATCH="$batch_size"
  LFM_CFG_UBATCH="$ubatch_size"
  LFM_CFG_BATCH_THREADS="$batch_threads"
}

# -----------------------------------------------------------------------------
# State file (machine-readable, used by update + status page)
# -----------------------------------------------------------------------------
lfm_state_write() {
  lfm_sudo mkdir -p "$LFM_DATA_ROOT"
  lfm_sudo tee "$LFM_STATE_FILE" >/dev/null <<EOF
{
  "llama_release": "${LFM_LLAMA_RELEASE:-}",
  "model": "${LFM_CFG_MODEL:-450m}",
  "installed_at": "$(date -u +%Y-%m-%dT%H:%M:%SZ)",
  "with_openwebui": ${LFM_CFG_OPENWEBUI:-false},
  "with_status_page": ${LFM_CFG_STATUS:-true},
  "arch": "$(lfm_detect_arch)",
  "os": "$(lfm_detect_os)"
}
EOF
  lfm_sudo chmod 644 "$LFM_STATE_FILE"
}

# -----------------------------------------------------------------------------
# Systemd service generation
# -----------------------------------------------------------------------------
lfm_write_api_service() {
  local bin_path="$1" model_path="$2" mmproj_path="$3"
  lfm_resolve_autos

  local service_file="/etc/systemd/system/${LFM_SERVICE_API}.service"
  local user="$LFM_USER"
  [ -z "$user" ] && user="root"

  local gpu_layers=0
  [ "$(lfm_detect_gpu)" = "nvidia" ] && gpu_layers=99

  lfm_sudo tee "$service_file" >/dev/null <<EOF
[Unit]
Description=lfm-vision API server (LFM2.5-VL vision-language model)
After=network-online.target
Wants=network-online.target

[Service]
Type=simple
User=${user}
WorkingDirectory=${LFM_DATA_ROOT}
Environment=LD_LIBRARY_PATH=${LFM_BIN_DIR}
ExecStart=${bin_path} \\
  -m ${model_path} \\
  --mmproj ${mmproj_path} \\
  --host 0.0.0.0 \\
  --port ${LFM_API_PORT} \\
  -c ${LFM_CFG_CTX} \\
  -t ${LFM_CFG_THREADS} \\
  -tb ${LFM_CFG_BATCH_THREADS} \\
  -np ${LFM_CFG_PARALLEL} \\
  -b ${LFM_CFG_BATCH} \\
  -ub ${LFM_CFG_UBATCH} \\
  --metrics \\
  -fa auto \\
  -ngl ${gpu_layers}
Restart=always
RestartSec=5
StandardOutput=append:${LFM_LOG_DIR}/api.log
StandardError=append:${LFM_LOG_DIR}/api.log

[Install]
WantedBy=multi-user.target
EOF
  log_ok "Wrote $service_file"
}

lfm_write_status_service() {
  local script_path="$1"  # path to the python status server
  local service_file="/etc/systemd/system/${LFM_SERVICE_STATUS}.service"
  local user="$LFM_USER"
  [ -z "$user" ] && user="root"

  lfm_sudo tee "$service_file" >/dev/null <<EOF
[Unit]
Description=lfm-vision status landing page
After=network-online.target ${LFM_SERVICE_API}.service
Wants=network-online.target

[Service]
Type=simple
User=${user}
Environment=LFM_API_PORT=${LFM_API_PORT}
Environment=LFM_STATUS_PORT=${LFM_STATUS_PORT}
Environment=LFM_STATUS_DIR=${LFM_STATUS_DIR}
Environment=LFM_DATA_ROOT=${LFM_DATA_ROOT}
ExecStart=/usr/bin/python3 ${script_path}
Restart=always
RestartSec=3
StandardOutput=append:${LFM_LOG_DIR}/status.log
StandardError=append:${LFM_LOG_DIR}/status.log

[Install]
WantedBy=multi-user.target
EOF
  log_ok "Wrote $service_file"
}

lfm_write_webui_service() {
  local venv_activate="$1"  # path to activate script
  local service_file="/etc/systemd/system/${LFM_SERVICE_WEBUI}.service"
  local user="$LFM_USER"
  [ -z "$user" ] && user="root"

  lfm_sudo tee "$service_file" >/dev/null <<EOF
[Unit]
Description=lfm-vision OpenWebUI frontend
After=network-online.target ${LFM_SERVICE_API}.service
Wants=network-online.target

[Service]
Type=simple
User=${user}
WorkingDirectory=${LFM_USER_HOME}
Environment=OPENAI_API_BASE_URL=http://127.0.0.1:${LFM_API_PORT}/v1
ExecStart=/bin/bash -c 'source ${venv_activate} && exec open-webui serve --host 0.0.0.0 --port ${LFM_WEBUI_PORT}'
Restart=always
RestartSec=3
StandardOutput=append:${LFM_LOG_DIR}/webui.log
StandardError=append:${LFM_LOG_DIR}/webui.log

[Install]
WantedBy=multi-user.target
EOF
  log_ok "Wrote $service_file"
}

# -----------------------------------------------------------------------------
# Service management helpers
# -----------------------------------------------------------------------------
lfm_daemon_reload() {
  lfm_sudo systemctl daemon-reload
}

lfm_service_enable_start() {
  local svc="$1"
  lfm_sudo systemctl enable "$svc" >/dev/null
  lfm_sudo systemctl restart "$svc"
}

lfm_service_stop_disable() {
  local svc="$1"
  lfm_sudo systemctl stop "$svc" 2>/dev/null || true
  lfm_sudo systemctl disable "$svc" 2>/dev/null || true
}

# Poll llama-server /health until it responds (or timeout)
lfm_wait_for_api() {
  local timeout="${1:-90}" url="http://127.0.0.1:${LFM_API_PORT}/health"
  log_info "Waiting for API at $url (up to ${timeout}s)"
  local i
  for i in $(seq 1 $((timeout / 3))); do
    if curl -sf "$url" >/dev/null 2>&1; then
      log_ok "API is up after ~$((i * 3))s"
      return 0
    fi
    sleep 3
  done
  log_warn "API did not respond in ${timeout}s"
  return 1
}

# -----------------------------------------------------------------------------
# Argument parsing
# -----------------------------------------------------------------------------
# Precedence: defaults < config file < CLI args < preset defaults (where set
# explicitly via PRESET_* in the entry script).
#
# Algorithm: start from defaults + config file (whichever exists), then let
# CLI args override. We track which CLI args were *explicitly* set so we
# don't clobber them.
lfm_parse_args() {
  # ---- layer 1: defaults (preset-aware) ----
  LFM_CFG_MODEL="450m"
  # PRESET_STATUS_PAGE / PRESET_OPENWEBUI are set by the entry script before
  # calling lfm_parse_args. If unset, fall back to safe defaults.
  LFM_CFG_STATUS="${PRESET_STATUS_PAGE:-true}"
  LFM_CFG_OPENWEBUI="${PRESET_OPENWEBUI:-false}"
  LFM_CFG_CTX="auto"
  LFM_CFG_THREADS="auto"
  LFM_CFG_PARALLEL="auto"
  LFM_API_PORT="${LFM_API_PORT:-8000}"
  LFM_STATUS_PORT="${LFM_STATUS_PORT:-80}"
  LFM_WEBUI_PORT="${LFM_WEBUI_PORT:-8080}"
  LFM_ACTION="install"  # install | update | uninstall

  # ---- layer 2: config file (overrides preset defaults) ----
  if [ -f "$LFM_CONFIG_FILE" ] && [ "$LFM_ACTION" = "install" ]; then
    local v
    v="$(lfm_config_get model)";            [ -n "$v" ] && LFM_CFG_MODEL="$v"
    v="$(lfm_config_get api_port)";         [ -n "$v" ] && LFM_API_PORT="$v"
    v="$(lfm_config_get status_port)";      [ -n "$v" ] && LFM_STATUS_PORT="$v"
    v="$(lfm_config_get webui_port)";       [ -n "$v" ] && LFM_WEBUI_PORT="$v"
    v="$(lfm_config_get with_openwebui)";   [ -n "$v" ] && LFM_CFG_OPENWEBUI="$v"
    v="$(lfm_config_get with_status_page)"; [ -n "$v" ] && LFM_CFG_STATUS="$v"
    v="$(lfm_config_get context_size)";     [ -n "$v" ] && LFM_CFG_CTX="$v"
    v="$(lfm_config_get threads)";          [ -n "$v" ] && LFM_CFG_THREADS="$v"
    v="$(lfm_config_get parallel)";         [ -n "$v" ] && LFM_CFG_PARALLEL="$v"
  fi

  # ---- layer 3: CLI args (overrides everything above) ----
  while [ $# -gt 0 ]; do
    case "$1" in
      --model)        LFM_CFG_MODEL="$2"; shift 2 ;;
      --model=*)      LFM_CFG_MODEL="${1#*=}"; shift ;;
      --port)         LFM_API_PORT="$2"; shift 2 ;;
      --port=*)       LFM_API_PORT="${1#*=}"; shift ;;
      --status-port)  LFM_STATUS_PORT="$2"; shift 2 ;;
      --webui-port)   LFM_WEBUI_PORT="$2"; shift 2 ;;
      --context)      LFM_CFG_CTX="$2"; shift 2 ;;
      --context=*)    LFM_CFG_CTX="${1#*=}"; shift ;;
      --threads)      LFM_CFG_THREADS="$2"; shift 2 ;;
      --parallel)     LFM_CFG_PARALLEL="$2"; shift 2 ;;
      --with-openwebui)    LFM_CFG_OPENWEBUI="true"; shift ;;
      --no-openwebui)      LFM_CFG_OPENWEBUI="false"; shift ;;
      --with-status-page)  LFM_CFG_STATUS="true"; shift ;;
      --no-status-page)    LFM_CFG_STATUS="false"; shift ;;
      --update)       LFM_ACTION="update"; shift ;;
      --uninstall)    LFM_ACTION="uninstall"; shift ;;
      --config)       LFM_CONFIG_FILE="$2"; shift 2 ;;
      --non-interactive) LFM_NONINTERACTIVE=1; shift ;;
      --list-models)  lfm_list_models; exit 0 ;;
      -h|--help)      lfm_print_help; exit 0 ;;
      *)              log_warn "Unknown argument: $1"; shift ;;
    esac
  done
}

lfm_print_help() {
  cat <<'EOF'
lfm-vision installer

Usage: install.sh [OPTIONS]

Install options:
  --model ID            Model to install (default: 450m). Use --list-models to see all.
  --port N              API port (default: 8000)
  --status-port N       Status page port (default: 80)
  --webui-port N        OpenWebUI port (default: 8080)
  --context N           Context size in tokens (default: auto-detect from RAM)
  --threads N           CPU threads for llama.cpp (default: auto)
  --parallel N          Parallel request slots (default: auto)
  --with-openwebui      Also install OpenWebUI on :8080
  --no-openwebui        Skip OpenWebUI (default)
  --with-status-page    Install status landing page (default)
  --no-status-page      Skip status page
  --config PATH         Use a custom config file
  --non-interactive     Don't prompt; use defaults

Lifecycle:
  --update              Pull latest llama.cpp release, rebuild/redownload, restart
  --uninstall           Remove everything installed by this script

Other:
  --list-models         Show available models and exit
  -h, --help            This help

Examples:
  curl -fsSL https://raw.githubusercontent.com/<you>/lai450MVL2.5/main/setandrunall.sh | bash
  curl -fsSL .../setandrunall.sh | bash -s -- --with-openwebui --port 9000
  curl -fsSL .../setandrunall.sh | bash -s -- --update
  curl -fsSL .../setandrunall.sh | bash -s -- --uninstall
EOF
}

# -----------------------------------------------------------------------------
# Pre-flight checks
# -----------------------------------------------------------------------------
lfm_preflight() {
  log_step "Pre-flight checks"

  # Need root for system-wide install
  if [ "$(id -u)" != "0" ] && ! command -v sudo >/dev/null 2>&1; then
    die "This installer needs root or sudo to install system services."
  fi

  # Detect OS
  local os
  os="$(lfm_detect_os)"
  case "$os" in
    ubuntu|debian|linuxmint|pop) ;;
    *) log_warn "OS '$os' not tested. Ubuntu/Debian recommended." ;;
  esac

  # Arch
  local arch
  arch="$(lfm_detect_arch)"
  log_info "Architecture: $arch"

  # Disk space (need ~2GB for llama.cpp + model)
  local avail_kb
  avail_kb="$(df -P /opt 2>/dev/null | awk 'NR==2 {print $4}')"
  if [ -n "$avail_kb" ] && [ "$avail_kb" -lt 2000000 ]; then
    log_warn "Less than 2GB free in /opt. The install may fail."
  fi

  # Existing install?
  if [ -f "$LFM_VERSION_FILE" ] && [ "$LFM_ACTION" = "install" ]; then
    log_info "Existing install detected:"
    cat "$LFM_VERSION_FILE" | sed 's/^/    /'
    log_info "Re-running will update. Use --update explicitly to suppress prompts."
  fi
}

# -----------------------------------------------------------------------------
# Banner
# -----------------------------------------------------------------------------
lfm_banner() {
  printf '%b' "$_C_BOLD$_C_MAGENTA" >&2
  cat >&2 <<'EOF'
  _      __ _       __     __     _  _
 | |    / /| |     / /__  / /_   | |(_)_______
 | |   / / | | /| / // _ \/ __ \  | | / / ___/
 | |  / /__| |/ |/ //  __/ /_/ /  | |/ (__  )
 |_| /____/|__/|__/ \___|_.___/   |___/____(_)
EOF
  printf '%b' "$_C_RESET" >&2
  printf '%b' "  Self-hosted vision AI · one command\n\n" >&2
}
