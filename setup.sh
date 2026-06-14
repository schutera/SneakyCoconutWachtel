#!/usr/bin/env bash
# maschinenraum — one-shot, idempotent setup (Docker Compose).
#   git clone … && cd maschinenraum && ./setup.sh
# Installs Docker + NVIDIA container toolkit if needed, then brings up vLLM
# (text+vision), optional Whisper STT, a Caddy router, a Cloudflare tunnel, and
# a Discord notifier. Safe to re-run.
set -euo pipefail
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib/common.sh"
source "$MR_HOME/lib/detect_gpu.sh"
source "$MR_HOME/lib/pick_model.sh"
source "$MR_HOME/lib/notify.sh"

set_env() {  # set or replace KEY=value in .env
  local key="$1" val="$2" file="$MR_HOME/.env"
  python3 - "$file" "$key" "$val" <<'PY'
import sys, pathlib
path, key, val = pathlib.Path(sys.argv[1]), sys.argv[2], sys.argv[3]
lines = path.read_text().splitlines() if path.exists() else []
out, done = [], False
for ln in lines:
    if ln.startswith(key + "="):
        out.append(f"{key}={val}"); done = True
    else:
        out.append(ln)
if not done:
    out.append(f"{key}={val}")
path.write_text("\n".join(out) + "\n")
PY
}

# ── 1. preflight ───────────────────────────────────────────────────────────
log "Preflight checks…"
[ "$(uname -s)" = "Linux" ] || die "This setup targets Linux + NVIDIA. Detected $(uname -s)."
require_gpu
for c in curl python3; do command -v "$c" >/dev/null || die "missing required tool: $c"; done
command -v sudo >/dev/null || die "sudo is required to install Docker / the NVIDIA toolkit."
mkdir -p "$MR_LOG_DIR" "$MR_STATE_DIR" "$MR_HOME/data/hf" "$MR_HOME/data/caddy"
log "GPU: $(gpu_name) · $(gpu_vram_mib) MiB VRAM"

# ── 2. Docker + NVIDIA container toolkit ───────────────────────────────────
if ! command -v docker >/dev/null 2>&1; then
  log "Installing Docker…"
  curl -fsSL https://get.docker.com | sudo sh
  sudo usermod -aG docker "${SUDO_USER:-$USER}" || true
fi
docker compose version >/dev/null 2>&1 || die "Docker Compose v2 not available — update Docker."

# Install the NVIDIA toolkit only if GPUs aren't already visible to Docker.
if ! sudo docker run --rm --gpus all nvidia/cuda:12.4.1-base-ubuntu22.04 nvidia-smi >/dev/null 2>&1; then
  if command -v apt-get >/dev/null 2>&1; then
    log "Installing NVIDIA container toolkit…"
    curl -fsSL https://nvidia.github.io/libnvidia-container/gpgkey \
      | sudo gpg --dearmor -o /usr/share/keyrings/nvidia-container-toolkit-keyring.gpg
    curl -s -L https://nvidia.github.io/libnvidia-container/stable/deb/nvidia-container-toolkit.list \
      | sed 's#deb https://#deb [signed-by=/usr/share/keyrings/nvidia-container-toolkit-keyring.gpg] https://#g' \
      | sudo tee /etc/apt/sources.list.d/nvidia-container-toolkit.list >/dev/null
    sudo apt-get update -qq && sudo apt-get install -y -qq nvidia-container-toolkit
    sudo nvidia-ctk runtime configure --runtime=docker
    sudo systemctl restart docker
  else
    die "GPUs not visible to Docker and no apt-get to auto-install the NVIDIA toolkit.
Install nvidia-container-toolkit manually, then re-run: https://docs.nvidia.com/datacenter/cloud-native/"
  fi
fi

# ── 3. config (.env) ───────────────────────────────────────────────────────
[ -f "$MR_HOME/.env" ] || { cp "$MR_HOME/.env.example" "$MR_HOME/.env"; log "Created .env from template."; }
load_env

if [ -z "${MR_API_KEY:-}" ]; then
  set_env MR_API_KEY "mr-$(openssl rand -hex 24)"; log "Generated MR_API_KEY."
fi
if [ -z "${MR_MODEL:-}" ]; then
  model="$(pick_text_model "$(gpu_vram_mib)")"
  set_env MR_MODEL "$model"; log "Auto-picked model: $model  (override MR_MODEL in .env)"
fi
load_env

ENABLE_WHISPER="$(cfg MR_ENABLE_WHISPER true)"
if [ "$ENABLE_WHISPER" = "true" ]; then
  set_env MR_EDGE_PORT "$(cfg MR_EDGE_PORT 8080)"
else
  set_env MR_EDGE_PORT "$(cfg MR_PORT 8000)"
fi
load_env

# ── 4. Caddy router config ─────────────────────────────────────────────────
{
  echo "{"
  echo -e "\tadmin off"
  echo -e "\tauto_https off"
  echo "}"
  echo ":$(cfg MR_EDGE_PORT 8080) {"
  if [ "$ENABLE_WHISPER" = "true" ]; then
    echo -e "\t@audio path /v1/audio/*"
    echo -e "\thandle @audio {"
    echo -e "\t\treverse_proxy whisper:$(cfg MR_WHISPER_PORT 8001)"
    echo -e "\t}"
  fi
  echo -e "\thandle {"
  echo -e "\t\treverse_proxy vllm:$(cfg MR_PORT 8000)"
  echo -e "\t}"
  echo "}"
} > "$MR_HOME/Caddyfile"
log "Wrote Caddyfile."

# ── 5. reconcile GPU memory split (avoid two-process OOM) ───────────────────
# core + whisper fractions must leave headroom for activation spikes.
CORE_FRAC="$(cfg MR_GPU_MEMORY_UTILIZATION 0.90)"
if [ "$ENABLE_WHISPER" = "true" ]; then
  # Only auto-lower if the user left the default; respect an explicit value.
  awk "BEGIN{exit !($CORE_FRAC > 0.82)}" && CORE_FRAC=0.80
  export MR_GPU_MEMORY_UTILIZATION="$CORE_FRAC"
  log "Whisper on → core GPU fraction $CORE_FRAC + whisper $(cfg MR_WHISPER_GPU_FRACTION 0.10)."
fi

# ── 6. choose profiles + bring the stack up ────────────────────────────────
profiles=()
[ "$ENABLE_WHISPER" = "true" ] && profiles+=(whisper)
if [ -n "${CLOUDFLARE_TUNNEL_TOKEN:-}" ]; then profiles+=(tunnel-token); else profiles+=(tunnel-quick); fi
export COMPOSE_PROFILES="$(IFS=,; echo "${profiles[*]}")"
log "Compose profiles: $COMPOSE_PROFILES"

log "Pulling images + starting (first run downloads the model — be patient)…"
sudo -E docker compose -f "$MR_HOME/docker-compose.yml" up -d --remove-orphans

# ── 7. verify + announce ───────────────────────────────────────────────────
log "Waiting for the API…"
ok=false
for _ in $(seq 1 180); do
  if curl -fsS -m 3 -H "Authorization: Bearer $(cfg MR_API_KEY)" \
       "http://127.0.0.1:$(cfg MR_PORT 8000)/health" >/dev/null 2>&1; then ok=true; break; fi
  sleep 5
done

# Quick tunnel: surface the ephemeral URL to Discord + console.
if [ -z "${CLOUDFLARE_TUNNEL_TOKEN:-}" ]; then
  url="$(sudo docker compose -f "$MR_HOME/docker-compose.yml" logs cloudflared-quick 2>/dev/null \
        | grep -Eo 'https://[a-z0-9-]+\.trycloudflare\.com' | head -n1 || true)"
  if [ -n "$url" ]; then
    log "Quick tunnel: $url"
    discord_send "🌍 **maschinenraum** reachable at <$url> (ephemeral — set CLOUDFLARE_TUNNEL_TOKEN for a stable hostname)."
  fi
fi

echo
[ "$ok" = true ] && log "✅ maschinenraum is up." \
  || warn "API not answering yet — large models take time. Logs: sudo docker compose logs -f vllm"
host="$(cfg MR_PUBLIC_HOSTNAME)"; [ -n "$host" ] && host="https://$host" || host="(quick-tunnel URL above / in Discord)"
cat <<EOF

  Endpoint (local):  http://localhost:$(cfg MR_PORT 8000)/v1
  Endpoint (remote): $host
  API key:           in .env (MR_API_KEY)

  Quick test:
    source .env && curl http://localhost:$(cfg MR_PORT 8000)/v1/chat/completions \\
      -H "Authorization: Bearer \$MR_API_KEY" -H "Content-Type: application/json" \\
      -d '{"model":"maschinenraum","messages":[{"role":"user","content":"hi"}]}'

  See readme.md for terminal-AI, chat-UI, and custom-app setup.
EOF
