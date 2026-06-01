#!/usr/bin/env bash
# lib/install.sh - Shared install pipeline for all lfm-vision entry scripts
#
# Sourced (or embedded) by the 4 entry scripts. Each entry script must define
#   install_llama_strategy()    # performs the llama.cpp install, sets LFM_LLAMA_BIN + LFM_LLAMA_RELEASE
#   PRESET_NAME=""              # shown in version file
#   PRESET_TAGLINE=""           # shown by --preset-info
#   PRESET_STATUS_PAGE="true"   # install status page by default
#   PRESET_OPENWEBUI="false"    # install OpenWebUI by default
# Then this file provides:
#   - install_model
#   - install_status_page
#   - install_openwebui
#   - write_config_and_state
#   - enable_services
#   - run_smoke_test
#   - print_summary
#   - action_update
#   - action_uninstall
#   - main_dispatch
#
# Requires lib/common.sh to be sourced first.

install_model() {
  local id="$1"
  if ! lfm_lookup_model "$id"; then
    log_error "Unknown model: $id"
    log_info "Available:"
    lfm_list_models
    die "Use --model to pick one."
  fi
  log_step "Installing model: ${id} (${LFM_MODEL_DESC})"

  lfm_sudo mkdir -p "$LFM_MODEL_DIR"
  lfm_download "$(lfm_model_url)"  "$LFM_MODEL_DIR/model.gguf"
  lfm_download "$(lfm_mmproj_url)" "$LFM_MODEL_DIR/mmproj.gguf"
}

install_status_page_assets() {
  log_step "Installing status landing page"
  local src_dir="${LFM_ENTRY_DIR:-$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)}/status-page"
  # LFM_ENTRY_DIR is set by entry scripts; fall back to alongside lib/
  lfm_sudo mkdir -p "$LFM_STATUS_DIR"
  if [ -d "$src_dir" ]; then
    lfm_sudo install -m 644 "$src_dir/index.html" "$LFM_STATUS_DIR/index.html"
    lfm_sudo install -m 644 "$src_dir/style.css"  "$LFM_STATUS_DIR/style.css"
    lfm_sudo install -m 644 "$src_dir/app.js"     "$LFM_STATUS_DIR/app.js"
    lfm_sudo install -m 755 "$src_dir/server.py"  "$LFM_STATUS_DIR/server.py"
  else
    local repo_base="${LFM_REPO_BASE:-https://raw.githubusercontent.com/ananyabhardwajjiit/lai450MVL2.5/main}"
    lfm_download "$repo_base/status-page/index.html"  "$LFM_STATUS_DIR/index.html"
    lfm_download "$repo_base/status-page/style.css"   "$LFM_STATUS_DIR/style.css"
    lfm_download "$repo_base/status-page/app.js"      "$LFM_STATUS_DIR/app.js"
    lfm_download "$repo_base/status-page/server.py"   "$LFM_STATUS_DIR/server.py"
  fi
  log_ok "Status page installed at $LFM_STATUS_DIR"
}

install_openwebui() {
  log_step "Installing OpenWebUI"
  lfm_sudo apt-get install -y --no-install-recommends software-properties-common >/dev/null
  if ! command -v python3.11 >/dev/null 2>&1; then
    lfm_sudo add-apt-repository -y ppa:deadsnakes/ppa >/dev/null
    lfm_sudo apt-get update -qq
    lfm_sudo apt-get install -y --no-install-recommends python3.11 python3.11-venv python3.11-distutils
  fi

  local venv="$LFM_DATA_ROOT/webui-venv"
  lfm_sudo rm -rf "$venv"
  lfm_sudo mkdir -p "$LFM_DATA_ROOT"
  lfm_sudo python3.11 -m venv "$venv"
  lfm_sudo "$venv/bin/pip" install --upgrade pip >/dev/null
  lfm_sudo "$venv/bin/pip" install open-webui >/dev/null
  lfm_sudo "$venv/bin/pip" show open-webui >/dev/null 2>&1 \
    || die "OpenWebUI install failed"
  log_ok "OpenWebUI installed in $venv"
  LFM_WEBUI_VENV="$venv"
}

write_config_and_state() {
  log_step "Writing config and state files"
  lfm_config_init
  lfm_state_write
  lfm_sudo mkdir -p "$LFM_LOG_DIR"
  lfm_sudo tee "$LFM_VERSION_FILE" >/dev/null <<EOF
lfm-vision 1.0
  preset:    $PRESET_NAME
  model:     $LFM_CFG_MODEL
  llama.cpp: ${LFM_LLAMA_RELEASE:-unknown}
  arch:      $(lfm_detect_arch)
  installed: $(date -u +%Y-%m-%dT%H:%M:%SZ)
EOF
}

enable_services() {
  log_step "Enabling and starting services"
  lfm_daemon_reload
  lfm_service_enable_start "$LFM_SERVICE_API"
  lfm_wait_for_api 90 || {
    log_warn "API did not start. Recent logs:"
    lfm_sudo tail -n 50 "${LFM_LOG_DIR}/api.log" 2>/dev/null || true
  }

  if [ "$LFM_CFG_STATUS" = "true" ]; then
    lfm_service_enable_start "$LFM_SERVICE_STATUS"
  else
    lfm_service_stop_disable "$LFM_SERVICE_STATUS"
  fi

  if [ "$LFM_CFG_OPENWEBUI" = "true" ]; then
    lfm_service_enable_start "$LFM_SERVICE_WEBUI"
  else
    lfm_service_stop_disable "$LFM_SERVICE_WEBUI"
  fi
}

run_smoke_test() {
  log_step "Smoke test"
  local out
  out="$(curl -s "http://127.0.0.1:${LFM_API_PORT}/v1/models" || true)"
  if echo "$out" | grep -q '"data"'; then
    log_ok "API responds with model list"
  else
    log_warn "API did not return a model list. Check: journalctl -u ${LFM_SERVICE_API} -n 80"
    return 1
  fi

  if [ "$LFM_CFG_STATUS" = "true" ]; then
    sleep 2
    if curl -sf "http://127.0.0.1:${LFM_STATUS_PORT}/api/status" >/dev/null 2>&1; then
      log_ok "Status page responds at :${LFM_STATUS_PORT}"
    else
      log_warn "Status page did not respond at :${LFM_STATUS_PORT}"
    fi
  fi
}

print_summary() {
  local ip
  ip="$(curl -s --max-time 5 ifconfig.me 2>/dev/null || hostname -I 2>/dev/null | awk '{print $1}' || echo '<server-ip>')"

  printf '\n%b\n' "$_C_BOLD$_C_GREEN"
  cat <<EOF
   lfm-vision is installed
   ───────────────────────
   Preset:    $PRESET_NAME
   Model:     ${LFM_CFG_MODEL} (${LFM_LLAMA_RELEASE:-unknown})
   API:       http://${ip}:${LFM_API_PORT}/v1
EOF
  if [ "$LFM_CFG_STATUS" = "true" ]; then
    cat <<EOF
   Status:    http://${ip}:${LFM_STATUS_PORT}/
EOF
  fi
  if [ "$LFM_CFG_OPENWEBUI" = "true" ]; then
    cat <<EOF
   Web UI:    http://${ip}:${LFM_WEBUI_PORT}/
EOF
  fi
  cat <<EOF

   Useful commands:
     systemctl status ${LFM_SERVICE_API}     # API status
     journalctl -u ${LFM_SERVICE_API} -f      # API logs
     curl http://${ip}:${LFM_STATUS_PORT}/api/status  # JSON status

   Update:   re-run this script with --update
   Remove:   re-run this script with --uninstall
EOF
  printf '%b\n' "$_C_RESET"
}

action_update() {
  log_step "Updating llama.cpp to the latest release"
  install_dependencies_minimal
  local release arch
  arch="$(lfm_detect_arch)"
  release="$(lfm_latest_llama_release)"

  if [ -f "$LFM_VERSION_FILE" ] && grep -q "$release" "$LFM_VERSION_FILE" 2>/dev/null; then
    log_ok "Already on $release. Nothing to do."
    return 0
  fi

  install_llama_strategy "$release" "$arch"
  lfm_service_enable_start "$LFM_SERVICE_API"
  lfm_wait_for_api 90 || log_warn "API did not come back up; check logs."

  lfm_sudo sed -i "s/^  llama.cpp:.*/  llama.cpp: $release/" "$LFM_VERSION_FILE"
  log_ok "Updated to $release"
}

action_uninstall() {
  log_step "Removing lfm-vision"
  for svc in "$LFM_SERVICE_WEBUI" "$LFM_SERVICE_STATUS" "$LFM_SERVICE_API"; do
    lfm_service_stop_disable "$svc"
    lfm_sudo rm -f "/etc/systemd/system/${svc}.service"
  done
  lfm_daemon_reload
  lfm_sudo rm -rf "$LFM_INSTALL_ROOT" "$LFM_DATA_ROOT" "$LFM_LOG_DIR" "$LFM_CONFIG_DIR"
  log_ok "Removed. /opt/lfm-vision, /var/lib/lfm-vision, /etc/lfm-vision deleted."
}

install_dependencies_minimal() {
  # Used by all presets - just curl, wget, ca-certificates, tar
  lfm_sudo apt-get update -qq
  lfm_sudo apt-get install -y --no-install-recommends \
    curl wget ca-certificates tar
}

install_dependencies_full() {
  # Used when status page / OpenWebUI is wanted
  install_dependencies_minimal
  lfm_sudo apt-get install -y --no-install-recommends python3 python3-venv python3-pip
}

# =============================================================================
# Main dispatch
# =============================================================================
main_dispatch() {
  lfm_banner
  lfm_parse_args "$@"

  # Apply preset defaults before the config-file layer
  LFM_CFG_STATUS="${LFM_CFG_STATUS:-$PRESET_STATUS_PAGE}"
  LFM_CFG_OPENWEBUI="${LFM_CFG_OPENWEBUI:-$PRESET_OPENWEBUI}"

  if [ "${1:-}" = "--list-models" ]; then
    lfm_list_models
    return 0
  fi
  if [ "${1:-}" = "--preset-info" ]; then
    printf '  %s%-22s%s  %s\n' "$_C_BOLD" "$PRESET_NAME" "$_C_RESET" "$PRESET_TAGLINE"
    return 0
  fi

  lfm_preflight

  case "$LFM_ACTION" in
    uninstall)
      action_uninstall
      return 0
      ;;
    update)
      action_update
      return 0
      ;;
  esac

  # Install OS deps
  if [ "$LFM_CFG_STATUS" = "true" ] || [ "$LFM_CFG_OPENWEBUI" = "true" ]; then
    install_dependencies_full
  else
    install_dependencies_minimal
  fi

  # Resolve hardware
  local arch tune
  arch="$(lfm_detect_arch)"
  tune="$(lfm_autotune)"
  eval "$tune"
  log_info "CPU threads: $cpu_threads · RAM: ${ram_mb}MB · GPU: $gpu · arch: $arch"
  lfm_resolve_autos
  log_info "Will use: context=${LFM_CFG_CTX} threads=${LFM_CFG_THREADS} parallel=${LFM_CFG_PARALLEL}"

  # Install model
  install_model "$LFM_CFG_MODEL"

  # Install llama.cpp via the strategy defined by the entry script
  local release="${LFM_LLAMA_RELEASE_OVERRIDE:-$(lfm_latest_llama_release)}"
  install_llama_strategy "$release" "$arch"

  # Status page
  if [ "$LFM_CFG_STATUS" = "true" ]; then
    install_status_page_assets
    lfm_write_status_service "$LFM_STATUS_DIR/server.py"
  fi

  # API service
  lfm_write_api_service "$LFM_LLAMA_BIN" "$LFM_MODEL_DIR/model.gguf" "$LFM_MODEL_DIR/mmproj.gguf"

  # Optional OpenWebUI
  if [ "$LFM_CFG_OPENWEBUI" = "true" ]; then
    install_openwebui
    lfm_write_webui_service "$LFM_WEBUI_VENV/bin/activate"
  fi

  write_config_and_state
  enable_services
  run_smoke_test
  print_summary
}
