#!/usr/bin/env bash
# Launches a vLLM server. Called by the systemd units, or directly for testing.
#   ./run.sh core      text + vision model on MR_PORT   (the main endpoint)
#   ./run.sh whisper   Whisper STT on MR_WHISPER_PORT    (internal, behind Caddy)
set -euo pipefail
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib/common.sh"
source "$MR_HOME/lib/pick_model.sh"
source "$MR_HOME/lib/detect_gpu.sh"
load_env

require_gpu
VLLM="$MR_VENV/bin/vllm"
[ -x "$VLLM" ] || die "vLLM not installed in $MR_VENV — run ./setup.sh first."

API_KEY="$(cfg MR_API_KEY)"
[ -n "$API_KEY" ] || die "MR_API_KEY is empty — run ./setup.sh to generate one."

case "${1:-core}" in
  core)
    MODEL="$(cfg MR_MODEL)"
    [ -n "$MODEL" ] || MODEL="$(pick_text_model "$(gpu_vram_mib)")"
    log "Serving text+vision model: $MODEL"
    # shellcheck disable=SC2086
    exec "$VLLM" serve "$MODEL" \
      --host "$(cfg MR_HOST 0.0.0.0)" \
      --port "$(cfg MR_PORT 8000)" \
      --api-key "$API_KEY" \
      --served-model-name maschinenraum \
      --gpu-memory-utilization "$(cfg MR_GPU_MEMORY_UTILIZATION 0.90)" \
      --enable-prefix-caching \
      ${MR_MAX_MODEL_LEN:+--max-model-len $MR_MAX_MODEL_LEN} \
      ${MR_MAX_NUM_SEQS:+--max-num-seqs $MR_MAX_NUM_SEQS} \
      $(cfg MR_EXTRA_ARGS)
    ;;
  whisper)
    MODEL="$(cfg MR_WHISPER_MODEL "$(pick_whisper_model)")"
    log "Serving Whisper STT: $MODEL"
    # Modest, fixed slice so it never starves the main model's KV cache.
    exec "$VLLM" serve "$MODEL" \
      --host 127.0.0.1 \
      --port "$(cfg MR_WHISPER_PORT 8001)" \
      --api-key "$API_KEY" \
      --gpu-memory-utilization "$(cfg MR_WHISPER_GPU_FRACTION 0.10)"
    ;;
  *)
    die "usage: run.sh [core|whisper]"
    ;;
esac
