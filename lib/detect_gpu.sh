#!/usr/bin/env bash
# GPU detection via nvidia-smi. Source for the functions, or run to print a summary.
set -euo pipefail
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/common.sh"

require_gpu() {
  command -v nvidia-smi >/dev/null 2>&1 \
    || die "nvidia-smi not found. This host needs an NVIDIA GPU + driver."
  nvidia-smi >/dev/null 2>&1 \
    || die "nvidia-smi present but failing — check the driver install."
}

# Total VRAM of GPU 0, in MiB.
gpu_vram_mib() {
  nvidia-smi --query-gpu=memory.total --format=csv,noheader,nounits -i 0 | tr -d ' '
}

gpu_name() {
  nvidia-smi --query-gpu=name --format=csv,noheader -i 0 | sed 's/^ *//;s/ *$//'
}

# One-line live telemetry: temp / util / mem-used — used by the health ping.
gpu_telemetry() {
  nvidia-smi --query-gpu=temperature.gpu,utilization.gpu,memory.used,memory.total \
    --format=csv,noheader,nounits -i 0 \
    | awk -F', ' '{printf "%s°C · %s%% util · %d/%d MiB", $1, $2, $3, $4}'
}

if [ "${BASH_SOURCE[0]}" = "${0}" ]; then
  require_gpu
  log "GPU:   $(gpu_name)"
  log "VRAM:  $(gpu_vram_mib) MiB"
  log "Live:  $(gpu_telemetry)"
fi
