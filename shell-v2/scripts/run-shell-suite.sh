#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"

cleanup() {
  jobs -p | xargs -r kill >/dev/null 2>&1 || true
}

trap cleanup EXIT INT TERM

cd "${ROOT_DIR}"

if [[ -z "${AXIA_V2_DOCK_GLASS:-}" ]]; then
  export AXIA_V2_DOCK_GLASS=0
fi

if [[ -z "${GSK_RENDERER:-}" ]]; then
  export GSK_RENDERER=gl
fi

./shell-v2/scripts/run-axia-power.sh --build-only >/dev/null 2>&1 || true
pkill -f "${ROOT_DIR}/zig-out/shell-v2/axia-power" >/dev/null 2>&1 || true
AXIA_POWER_PREWARM=1 "${ROOT_DIR}/zig-out/shell-v2/axia-power" >/dev/null 2>&1 &

start_delay="${AXIA_SHELL_V2_START_DELAY:-0.35}"
enable_dock="${AXIA_V2_ENABLE_DOCK:-1}"
enable_notifications="${AXIA_V2_ENABLE_NOTIFICATIONS:-0}"

if [[ -z "${AXIA_IPC_SOCKET:-}" && -n "${WAYLAND_DISPLAY:-}" ]]; then
  if [[ "${enable_dock}" == "1" || "${enable_dock}" == "true" || "${enable_dock}" == "yes" || "${enable_dock}" == "on" || "${enable_notifications}" == "1" || "${enable_notifications}" == "true" || "${enable_notifications}" == "yes" || "${enable_notifications}" == "on" ]]; then
    RUNTIME_DIR="${XDG_RUNTIME_DIR:-/tmp}"
    export AXIA_IPC_SOCKET="${RUNTIME_DIR%/}/axia-${WAYLAND_DISPLAY}.sock"
  fi
fi

if [[ "${enable_dock}" == "1" || "${enable_dock}" == "true" || "${enable_dock}" == "yes" || "${enable_dock}" == "on" ]]; then
  ./shell-v2/scripts/run-axia-dock.sh >/dev/null 2>&1 &
  sleep "${start_delay}"
fi
if [[ "${enable_notifications}" == "1" || "${enable_notifications}" == "true" || "${enable_notifications}" == "yes" || "${enable_notifications}" == "on" ]]; then
  ./shell-v2/scripts/run-notifications-shell.sh >/dev/null 2>&1 &
  sleep "${start_delay}"
fi
./shell-v2/scripts/run-axia-shell.sh
