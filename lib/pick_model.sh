#!/usr/bin/env bash
# Map detected VRAM -> a sensible default model, leaving KV-cache headroom for
# concurrent requests (we never pack the model to the brim). All picks are
# vision-language models, so a single process serves both text and images.
# Override any time with MR_MODEL in .env.
set -euo pipefail
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/common.sh"

# Args: <vram_mib>  ->  prints a HuggingFace model id.
pick_text_model() {
  local vram="${1:?vram in MiB required}"
  if   [ "$vram" -lt 10000 ]; then echo "Qwen/Qwen2.5-VL-3B-Instruct"
  elif [ "$vram" -lt 18000 ]; then echo "Qwen/Qwen2.5-VL-7B-Instruct"
  elif [ "$vram" -lt 28000 ]; then echo "Qwen/Qwen2.5-VL-32B-Instruct-AWQ"
  elif [ "$vram" -lt 50000 ]; then echo "Qwen/Qwen2.5-VL-72B-Instruct-AWQ"
  else                             echo "Qwen/Qwen2.5-VL-72B-Instruct"
  fi
}

# Whisper is small (~2-3 GB); large-v3-turbo is the best speed/quality tradeoff.
pick_whisper_model() { echo "openai/whisper-large-v3-turbo"; }

if [ "${BASH_SOURCE[0]}" = "${0}" ]; then
  source "$MR_HOME/lib/detect_gpu.sh"
  require_gpu
  vram="$(gpu_vram_mib)"
  log "VRAM ${vram} MiB -> text/vision: $(pick_text_model "$vram")"
  log "                -> whisper:      $(pick_whisper_model)"
fi
