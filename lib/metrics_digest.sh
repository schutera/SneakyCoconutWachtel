#!/usr/bin/env bash
# Reads vLLM's Prometheus /metrics endpoint + nvidia-smi and pushes a summary to
# Discord. This is the entire "observability stack" — no Grafana, no Prometheus
# server. Two modes:
#   health  — lightweight daily ping (alive? GPU? tokens today?)
#   digest  — weekly rollup (totals + averages, using a saved snapshot for deltas)
set -euo pipefail
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/common.sh"
source "$MR_HOME/lib/detect_gpu.sh"
source "$MR_HOME/lib/notify.sh"
load_env

PORT="$(cfg MR_PORT 8000)"
KEY="$(cfg MR_API_KEY)"
METRICS_URL="http://127.0.0.1:${PORT}/metrics"
mkdir -p "$MR_STATE_DIR"

# Sum a counter across all label sets (vLLM emits one series per model/engine).
metric_sum() {
  local name="$1" body="$2"
  printf '%s\n' "$body" \
    | awk -v m="$name" '$1 ~ "^"m"(\\{|$| )" {s+=$2} END {printf "%.0f", s+0}'
}

fetch_metrics() { curl -fsS -m 10 -H "Authorization: Bearer ${KEY}" "$METRICS_URL"; }

is_alive() { curl -fsS -m 5 -H "Authorization: Bearer ${KEY}" \
  "http://127.0.0.1:${PORT}/health" >/dev/null 2>&1; }

human() { # thousands separators for token counts
  printf "%'d" "$1" 2>/dev/null || printf "%d" "$1"
}

mode_health() {
  if ! is_alive; then
    discord_send "🔴 **maschinenraum** is DOWN — vLLM /health not responding on :${PORT}."
    return 0
  fi
  local body prompt gen
  body="$(fetch_metrics || true)"
  prompt="$(metric_sum 'vllm:prompt_tokens_total' "$body")"
  gen="$(metric_sum 'vllm:generation_tokens_total' "$body")"
  discord_send "$(cat <<EOF
🟢 **maschinenraum** healthy
• GPU: $(gpu_telemetry)
• Tokens served (since boot): $(human "$prompt") in / $(human "$gen") out
• Model: $(cfg MR_MODEL '?')
EOF
)"
}

mode_digest() {
  local snap="$MR_STATE_DIR/digest_snapshot.env"
  local body prompt gen now
  body="$(fetch_metrics || true)"
  prompt="$(metric_sum 'vllm:prompt_tokens_total' "$body")"
  gen="$(metric_sum 'vllm:generation_tokens_total' "$body")"
  now="$(date +%s)"

  local d_prompt="$prompt" d_gen="$gen" since="this boot"
  if [ -f "$snap" ]; then
    # shellcheck disable=SC1090
    . "$snap"
    # Counters reset to 0 on restart; only diff when current >= saved.
    [ "$prompt" -ge "${PREV_PROMPT:-0}" ] && d_prompt=$(( prompt - PREV_PROMPT ))
    [ "$gen"    -ge "${PREV_GEN:-0}"    ] && d_gen=$(( gen - PREV_GEN ))
    since="$(( (now - PREV_TS) / 86400 ))d"
  fi

  discord_send "$(cat <<EOF
📊 **maschinenraum — weekly digest** (last ${since})
• Tokens: $(human "$d_prompt") in / $(human "$d_gen") out
• Lifetime: $(human "$prompt") in / $(human "$gen") out
• GPU now: $(gpu_telemetry)
• Model: $(cfg MR_MODEL '?')
EOF
)"

  printf 'PREV_PROMPT=%s\nPREV_GEN=%s\nPREV_TS=%s\n' "$prompt" "$gen" "$now" > "$snap"
}

case "${1:-health}" in
  health) mode_health ;;
  digest) mode_digest ;;
  *) die "usage: metrics_digest.sh [health|digest]" ;;
esac
