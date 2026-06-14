#!/usr/bin/env bash
# maschinenraum — one-shot, idempotent setup.
#   git clone … && cd maschinenraum && ./setup.sh
# Installs vLLM (text+vision) + optional Whisper STT behind a Caddy router,
# wires a Cloudflare tunnel for remote access, autostart via systemd, and
# Discord health/digest pings. Safe to re-run.
set -euo pipefail
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib/common.sh"
source "$MR_HOME/lib/detect_gpu.sh"
source "$MR_HOME/lib/pick_model.sh"

MR_USER="${SUDO_USER:-$USER}"
SYSTEMD_DIR=/etc/systemd/system

# Set or replace KEY=value in .env (creates the line if absent).
set_env() {
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
for c in curl python3 sudo; do command -v "$c" >/dev/null || die "missing required tool: $c"; done
mkdir -p "$MR_LOG_DIR" "$MR_STATE_DIR"
log "GPU: $(gpu_name) · $(gpu_vram_mib) MiB VRAM"

# ── 2. config (.env) ───────────────────────────────────────────────────────
if [ ! -f "$MR_HOME/.env" ]; then
  cp "$MR_HOME/.env.example" "$MR_HOME/.env"
  log "Created .env from template — edit it for Cloudflare/Discord secrets."
fi
load_env

if [ -z "${MR_API_KEY:-}" ]; then
  newkey="mr-$(openssl rand -hex 24)"
  set_env MR_API_KEY "$newkey"
  log "Generated MR_API_KEY."
fi

if [ -z "${MR_MODEL:-}" ]; then
  model="$(pick_text_model "$(gpu_vram_mib)")"
  set_env MR_MODEL "$model"
  log "Auto-picked model for your VRAM: $model  (override MR_MODEL in .env)"
fi
load_env

ENABLE_WHISPER="$(cfg MR_ENABLE_WHISPER true)"

# Whisper off → Cloudflare points straight at vLLM; on → at the Caddy router.
if [ "$ENABLE_WHISPER" = "true" ]; then
  set_env MR_EDGE_PORT "$(cfg MR_EDGE_PORT 8080)"
else
  set_env MR_EDGE_PORT "$(cfg MR_PORT 8000)"
fi
load_env

# ── 3. python env + vLLM ───────────────────────────────────────────────────
if ! command -v uv >/dev/null 2>&1; then
  log "Installing uv…"
  curl -LsSf https://astral.sh/uv/install.sh | sh
  export PATH="$HOME/.local/bin:$PATH"
fi
if [ ! -x "$MR_VENV/bin/vllm" ]; then
  log "Creating venv + installing vLLM (this pulls CUDA wheels, be patient)…"
  uv venv "$MR_VENV" --python 3.12
  uv pip install --python "$MR_VENV/bin/python" vllm
else
  log "vLLM already installed — skipping."
fi

# ── 4. Caddy router (only if Whisper is enabled) ───────────────────────────
if [ "$ENABLE_WHISPER" = "true" ]; then
  if ! command -v caddy >/dev/null 2>&1; then
    log "Installing Caddy (single static binary)…"
    arch="$(uname -m)"; case "$arch" in x86_64) arch=amd64;; aarch64|arm64) arch=arm64;; esac
    sudo curl -fsSL "https://caddyserver.com/api/download?os=linux&arch=${arch}" -o /usr/bin/caddy
    sudo chmod +x /usr/bin/caddy
  fi
  cat > "$MR_HOME/Caddyfile" <<EOF
{
	admin off
	auto_https off
}
:$(cfg MR_EDGE_PORT 8080) {
	@audio path /v1/audio/*
	handle @audio {
		reverse_proxy 127.0.0.1:$(cfg MR_WHISPER_PORT 8001)
	}
	handle {
		reverse_proxy 127.0.0.1:$(cfg MR_PORT 8000)
	}
}
EOF
  log "Wrote Caddyfile (router: /v1/audio/* → Whisper, else → vLLM)."
fi

# ── 5. systemd units ───────────────────────────────────────────────────────
log "Installing systemd units…"
units=(maschinenraum-core.service maschinenraum-tunnel.service
       maschinenraum-health.service maschinenraum-health.timer
       maschinenraum-digest.service maschinenraum-digest.timer)
[ "$ENABLE_WHISPER" = "true" ] && units+=(maschinenraum-whisper.service maschinenraum-edge.service)

for u in "${units[@]}"; do
  sed -e "s|__MR_HOME__|$MR_HOME|g" -e "s|__MR_USER__|$MR_USER|g" \
    "$MR_HOME/systemd/$u" | sudo tee "$SYSTEMD_DIR/$u" >/dev/null
done
sudo systemctl daemon-reload

enable_units=(maschinenraum-core.service maschinenraum-tunnel.service
              maschinenraum-health.timer maschinenraum-digest.timer)
[ "$ENABLE_WHISPER" = "true" ] && enable_units+=(maschinenraum-whisper.service maschinenraum-edge.service)
sudo systemctl enable --now "${enable_units[@]}"

# ── 6. verify + announce ───────────────────────────────────────────────────
log "Waiting for the model to load and the API to come up…"
ok=false
for _ in $(seq 1 120); do
  if curl -fsS -m 3 -H "Authorization: Bearer $(cfg MR_API_KEY)" \
       "http://127.0.0.1:$(cfg MR_PORT 8000)/health" >/dev/null 2>&1; then
    ok=true; break
  fi
  sleep 5
done

"$MR_HOME/lib/metrics_digest.sh" health || true

echo
if [ "$ok" = true ]; then
  log "✅ maschinenraum is up."
else
  warn "API didn't answer yet — large models can take a while. Tail: journalctl -u maschinenraum-core -f"
fi
host="$(cfg MR_PUBLIC_HOSTNAME)"; [ -n "$host" ] && host="https://$host" || host="(see Discord for the quick-tunnel URL)"
cat <<EOF

  Endpoint (local):  http://localhost:$(cfg MR_PORT 8000)/v1
  Endpoint (remote): $host
  API key:           in .env (MR_API_KEY)

  Quick test:
    curl http://localhost:$(cfg MR_PORT 8000)/v1/chat/completions \\
      -H "Authorization: Bearer \$MR_API_KEY" -H "Content-Type: application/json" \\
      -d '{"model":"maschinenraum","messages":[{"role":"user","content":"hi"}]}'

  See README.md for terminal-AI, chat-UI, and custom-app setup.
EOF
