#!/usr/bin/env bash
# uninstall.sh - Remove lfm-vision
#
# Stops and disables all lfm-vision systemd services, removes the
# service unit files, the install root (/opt/lfm-vision), the data root
# (/var/lib/lfm-vision), the config dir (/etc/lfm-vision), and the log
# dir (/var/log/lfm-vision). Leaves the model files in $HOME/.cache
# alone (those are outside the install roots).
#
# Re-runs are safe. Aborts cleanly if lfm-vision isn't installed.
#
# Usage:
#   ./uninstall.sh
#   curl -fsSL https://raw.githubusercontent.com/ananyabhardwajjiit/lai450MVL2.5/main/uninstall.sh | bash
#
set -Eeuo pipefail

# Defaults match lib/common.sh
LFM_INSTALL_ROOT="${LFM_INSTALL_ROOT:-/opt/lfm-vision}"
LFM_DATA_ROOT="${LFM_DATA_ROOT:-/var/lib/lfm-vision}"
LFM_CONFIG_DIR="${LFM_CONFIG_DIR:-/etc/lfm-vision}"
LFM_LOG_DIR="${LFM_LOG_DIR:-/var/log/lfm-vision}"
LFM_SERVICE_API="lfm-vision-api"
LFM_SERVICE_STATUS="lfm-vision-status"
LFM_SERVICE_WEBUI="lfm-vision-webui"

# ---- colors (minimal) ----
if [ -t 1 ]; then
  C_RED=$'\033[31m'; C_GREEN=$'\033[32m'; C_YELLOW=$'\033[33m'
  C_BOLD=$'\033[1m'; C_RESET=$'\033[0m'
else
  C_RED=""; C_GREEN=""; C_YELLOW=""; C_BOLD=""; C_RESET=""
fi
log()  { printf '%b[INFO]%b %s\n' "$C_BOLD" "$C_RESET" "$*" >&2; }
ok()   { printf '%b[OK]%b   %s\n' "$C_GREEN" "$C_RESET" "$*" >&2; }
warn() { printf '%b[WARN]%b %s\n' "$C_YELLOW" "$C_RESET" "$*" >&2; }
err()  { printf '%b[ERR]%b  %s\n' "$C_RED" "$C_RESET" "$*" >&2; }
die()  { err "$@"; exit 1; }

sudo_run() { if [ "$(id -u)" = "0" ]; then "$@"; else sudo "$@"; fi; }

# ---- detect existing install ----
if ! [ -d "$LFM_INSTALL_ROOT" ] && ! [ -d "$LFM_DATA_ROOT" ] && \
   ! [ -f "/etc/systemd/system/${LFM_SERVICE_API}.service" ]; then
  die "lfm-vision does not appear to be installed. Nothing to do."
fi

log "Removing lfm-vision..."

# Stop & disable services
for svc in "$LFM_SERVICE_WEBUI" "$LFM_SERVICE_STATUS" "$LFM_SERVICE_API"; do
  if sudo_run systemctl list-unit-files "${svc}.service" >/dev/null 2>&1; then
    log "  stopping $svc"
    sudo_run systemctl stop "$svc" 2>/dev/null || true
    sudo_run systemctl disable "$svc" 2>/dev/null || true
  fi
  if [ -f "/etc/systemd/system/${svc}.service" ]; then
    log "  removing unit /etc/systemd/system/${svc}.service"
    sudo_run rm -f "/etc/systemd/system/${svc}.service"
  fi
done
sudo_run systemctl daemon-reload

# Remove directories
for d in "$LFM_INSTALL_ROOT" "$LFM_DATA_ROOT" "$LFM_CONFIG_DIR" "$LFM_LOG_DIR"; do
  if [ -d "$d" ]; then
    log "  removing $d"
    sudo_run rm -rf "$d"
  fi
done

# Note about model cache
if [ -d "${HOME}/.cache/llama.cpp" ] || [ -f "${HOME}/.cache/llama.cpp/model.gguf" ]; then
  warn "Note: model files in ${HOME}/.cache/llama.cpp were NOT removed."
  warn "      Delete manually with: rm -rf ~/.cache/llama.cpp"
fi

# Note about OpenWebUI user data
if [ -d "${HOME}/.open-webui" ]; then
  warn "Note: OpenWebUI user data in ${HOME}/.open-webui was NOT removed."
  warn "      Delete manually with: rm -rf ~/.open-webui"
fi

ok "lfm-vision has been removed."
ok "Reinstall at any time: curl -fsSL <repo>/setandrunall.sh | bash"
