#!/usr/bin/env bash
# Discord webhook notifier. No-op (with a warning) if DISCORD_WEBHOOK_URL is unset,
# so the rest of the system never fails just because notifications aren't configured.
set -euo pipefail
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/common.sh"
load_env

# discord_send "<message>"   — plain content, markdown supported by Discord.
discord_send() {
  local msg="$1"
  local url="${DISCORD_WEBHOOK_URL:-}"
  if [ -z "$url" ]; then
    warn "DISCORD_WEBHOOK_URL unset — skipping notification: $msg"
    return 0
  fi
  # Build JSON safely (escape quotes/newlines) without needing jq.
  local payload
  payload=$(printf '%s' "$msg" | python3 -c 'import json,sys; print(json.dumps({"content": sys.stdin.read()}))')
  curl -fsS -m 10 -H "Content-Type: application/json" -X POST -d "$payload" "$url" >/dev/null \
    || warn "Discord notification failed (webhook unreachable)."
}

if [ "${BASH_SOURCE[0]}" = "${0}" ]; then
  discord_send "${1:-🔧 maschinenraum test notification}"
fi
