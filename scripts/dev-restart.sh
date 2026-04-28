#!/bin/sh
set -eu

usage() {
  cat <<'USAGE'
Usage: scripts/dev-restart.sh <component> [args...]

Components:
  all          rebuild and restart panel, dock, launcher and app-grid
  panel        rebuild and restart axia-panel
  dock         rebuild and restart axia-dock
  launcher     rebuild and restart axia-launcher if it is open/requested
  app-grid     rebuild and restart axia-app-grid if it is open/requested
  files        rebuild and open axia-files
  settings     rebuild and open axia-settings
  compositor   rebuild only; restart the Axia session manually

Environment:
  AXIA_DEV_PREFIX    install prefix, default /tmp/axia-dev
  AXIA_DEV_OPTIMIZE  Zig optimize mode, default Debug
USAGE
}

if [ "${1:-}" = "" ]; then
  usage
  exit 2
fi

component="$1"
shift

case "$component" in
  -h|--help|help)
    usage
    exit 0
    ;;
esac

prefix="${AXIA_DEV_PREFIX:-/tmp/axia-dev}"
optimize="${AXIA_DEV_OPTIMIZE:-Debug}"

zig build -Doptimize="$optimize" -p "$prefix"

export AXIA_BIN_DIR="$prefix/bin"
export AXIA_ASSET_DIR="$prefix/share/axia-de/assets"

if [ -z "${AXIA_IPC_SOCKET:-}" ] && [ -n "${WAYLAND_DISPLAY:-}" ]; then
  runtime_dir="${XDG_RUNTIME_DIR:-/tmp}"
  candidate="$runtime_dir/axia-$WAYLAND_DISPLAY.sock"
  if [ -S "$candidate" ]; then
    export AXIA_IPC_SOCKET="$candidate"
  fi
fi

restart_process() {
  process="$1"
  if pkill -x "$process" 2>/dev/null; then
    printf 'Restart requested for %s.\n' "$process"
  else
    printf '%s was not running; rebuilt binary is ready.\n' "$process"
  fi
}

open_app() {
  binary="$1"
  shift
  if [ -z "${WAYLAND_DISPLAY:-}" ]; then
    printf 'WAYLAND_DISPLAY is not set; cannot open %s from this shell.\n' "$binary" >&2
    exit 1
  fi
  "$prefix/bin/$binary" "$@" &
  printf 'Started %s from %s.\n' "$binary" "$prefix"
}

case "$component" in
  all)
    restart_process axia-panel
    restart_process axia-dock
    restart_process axia-launcher
    restart_process axia-app-grid
    printf 'Panel and dock are supervised and should come back automatically.\n'
    ;;
  panel)
    restart_process axia-panel
    ;;
  dock)
    restart_process axia-dock
    ;;
  launcher)
    restart_process axia-launcher
    printf 'If launcher was closed, open it again with the normal shortcut.\n'
    ;;
  app-grid|app_grid)
    restart_process axia-app-grid
    printf 'If app-grid was closed, open it again with the normal shortcut.\n'
    ;;
  files)
    open_app axia-files "$@"
    ;;
  settings)
    open_app axia-settings "$@"
    ;;
  compositor|de|axia-de|session)
    printf 'Compositor rebuilt at %s/bin/axia-de.\n' "$prefix"
    printf 'Restart the Axia session to load compositor changes.\n'
    ;;
  *)
    printf 'Unknown component: %s\n\n' "$component" >&2
    usage >&2
    exit 2
    ;;
esac
