#!/usr/bin/env bash
# Shared helpers for maschinenraum scripts. Source this, don't run it.

# Resolve the repo root (parent of lib/) regardless of where we're called from.
MR_HOME="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
export MR_HOME

MR_VENV="$MR_HOME/.venv"
MR_STATE_DIR="$MR_HOME/data/state"
MR_LOG_DIR="$MR_HOME/data/logs"

# --- logging ---------------------------------------------------------------
log()  { printf '\033[1;34m[maschinenraum]\033[0m %s\n' "$*"; }
warn() { printf '\033[1;33m[maschinenraum] WARN:\033[0m %s\n' "$*" >&2; }
die()  { printf '\033[1;31m[maschinenraum] ERROR:\033[0m %s\n' "$*" >&2; exit 1; }

# --- config ----------------------------------------------------------------
# Load .env (KEY=VALUE lines) into the environment. Silent if absent.
load_env() {
  local env_file="${1:-$MR_HOME/.env}"
  [ -f "$env_file" ] || return 0
  set -a
  # shellcheck disable=SC1090
  . "$env_file"
  set +a
}

# Echo a config value with a fallback default.
cfg() { local name="$1" def="${2:-}"; local v="${!name:-}"; printf '%s' "${v:-$def}"; }
