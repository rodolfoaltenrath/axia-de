#!/bin/sh
set -eu

prefix="${AXIA_SESSION_CHECK_PREFIX:-${AXIA_DEV_PREFIX:-/tmp/axia-dev}}"
duration="${AXIA_SESSION_CHECK_SECONDS:-8}"
runtime_dir="$(mktemp -d /tmp/axia-runtime.XXXXXX)"
log_file="$(mktemp /tmp/axia-session-headless.XXXXXX.log)"

cleanup() {
  rm -rf "$runtime_dir"
}
trap cleanup EXIT INT TERM

require_log() {
  needle="$1"
  if ! grep -F "$needle" "$log_file" >/dev/null 2>&1; then
    printf 'missing expected session log: %s\n' "$needle" >&2
    printf '\nSession log: %s\n' "$log_file" >&2
    sed -n '1,160p' "$log_file" >&2
    exit 1
  fi
}

if [ ! -x "$prefix/bin/axia-session" ]; then
  printf 'missing executable session wrapper: %s/bin/axia-session\n' "$prefix" >&2
  exit 1
fi

chmod 700 "$runtime_dir"

set +e
timeout "$duration" env \
  XDG_RUNTIME_DIR="$runtime_dir" \
  WLR_BACKENDS=headless \
  WLR_LIBINPUT_NO_DEVICES=1 \
  "$prefix/bin/axia-session" >"$log_file" 2>&1
status="$?"
set -e

if [ "$status" -ne 0 ] && [ "$status" -ne 124 ]; then
  printf 'headless session exited unexpectedly with status %s\n' "$status" >&2
  printf '\nSession log: %s\n' "$log_file" >&2
  sed -n '1,200p' "$log_file" >&2
  exit "$status"
fi

require_log "Wayland socket ready"
require_log "configured output HEADLESS-1"
require_log "panel spawned"
require_log "dock spawned"
require_log "Axia-DE core is running"
require_log "configured panel surface"
require_log "configured dock surface"

printf 'Headless session smoke passed for %s\n' "$prefix"
printf 'Log: %s\n' "$log_file"
