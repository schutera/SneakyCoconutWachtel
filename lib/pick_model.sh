#!/usr/bin/env bash
# Map detected VRAM -> a sensible default model, leaving KV-cache headroom for
# concurrent requests (we never pack the model to the brim). All picks are
# vision-language models, so a single process serves both text and images.
# Override any time with MR_MODEL in .env.
set -euo pipefail
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/common.sh"

# Args: <vram_mib>  ->  prints a HuggingFace model id.
# Picks are deliberately conservative: a model that loads but OOMs under
# concurrent + vision load on first boot is the worst first impression. Bump up
# via MR_MODEL if you run low concurrency and want a bigger model.
pick_text_model() {
  local vram="${1:?vram in MiB required}"
  if   [ "$vram" -lt 10000 ]; then echo "Qwen/Qwen2.5-VL-3B-Instruct"   # 8 GB
  elif [ "$vram" -lt 26000 ]; then echo "Qwen/Qwen2.5-VL-7B-Instruct"   # 12-24 GB (safe w/ KV + vision)
  elif [ "$vram" -lt 50000 ]; then echo "Qwen/Qwen2.5-VL-32B-Instruct-AWQ"  # 32-48 GB
  else                             echo "Qwen/Qwen2.5-VL-72B-Instruct-AWQ"  # 80 GB
  fi
}

# faster-whisper (CTranslate2) default; overridable via MR_WHISPER_MODEL.
pick_whisper_model() { echo "Systran/faster-whisper-large-v3"; }

if [ "${BASH_SOURCE[0]}" = "${0}" ]; then
  source "$MR_HOME/lib/detect_gpu.sh"
  require_gpu
  vram="$(gpu_vram_mib)"
  log "VRAM ${vram} MiB -> text/vision: $(pick_text_model "$vram")"
  log "                -> whisper:      $(pick_whisper_model)"
fi
