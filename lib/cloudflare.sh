#!/usr/bin/env bash
# Cloudflare Tunnel front door. Two modes, auto-selected:
#   named tunnel  — if CLOUDFLARE_TUNNEL_TOKEN is set: stable hostname, survives
#                   restarts, configured in the Cloudflare dashboard.
#   quick tunnel  — otherwise: a free ephemeral *.trycloudflare.com URL, captured
#                   from the logs and posted to Discord so you always know it.
# Points at MR_EDGE_PORT (the Caddy router if Whisper is on, else vLLM directly).
set -euo pipefail
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/common.sh"
source "$MR_HOME/lib/notify.sh"
load_env

EDGE_PORT="$(cfg MR_EDGE_PORT "$(cfg MR_PORT 8000)")"
TARGET="http://127.0.0.1:${EDGE_PORT}"

ensure_cloudflared() {
  command -v cloudflared >/dev/null 2>&1 && return 0
  log "Installing cloudflared…"
  local arch; arch="$(uname -m)"
  case "$arch" in
    x86_64|amd64) arch=amd64 ;;
    aarch64|arm64) arch=arm64 ;;
    *) die "unsupported arch for cloudflared: $arch" ;;
  esac
  local url="https://github.com/cloudflare/cloudflared/releases/latest/download/cloudflared-linux-${arch}"
  sudo curl -fsSL "$url" -o /usr/local/bin/cloudflared
  sudo chmod +x /usr/local/bin/cloudflared
}

# Entrypoint used by the systemd service.
run() {
  ensure_cloudflared
  if [ -n "${CLOUDFLARE_TUNNEL_TOKEN:-}" ]; then
    log "Starting named Cloudflare tunnel -> ${TARGET}"
    exec cloudflared tunnel --no-autoupdate run --token "$CLOUDFLARE_TUNNEL_TOKEN"
  fi

  log "No CLOUDFLARE_TUNNEL_TOKEN set — starting an ephemeral quick tunnel -> ${TARGET}"
  local logf="$MR_LOG_DIR/cloudflared-quick.log"
  mkdir -p "$MR_LOG_DIR"
  cloudflared tunnel --no-autoupdate --url "$TARGET" >"$logf" 2>&1 &
  local pid=$!
  # Wait for the public URL to appear, then announce it.
  for _ in $(seq 1 30); do
    local found
    found="$(grep -Eo 'https://[a-z0-9-]+\.trycloudflare\.com' "$logf" | head -n1 || true)"
    if [ -n "$found" ]; then
      log "Quick tunnel live: $found"
      discord_send "🌍 **maschinenraum** reachable at <${found}> (ephemeral quick tunnel — changes on restart; set CLOUDFLARE_TUNNEL_TOKEN for a stable hostname)."
      break
    fi
    sleep 2
  done
  wait "$pid"
}

case "${1:-run}" in
  run) run ;;
  install) ensure_cloudflared ;;
  *) die "usage: cloudflare.sh [run|install]" ;;
esac
