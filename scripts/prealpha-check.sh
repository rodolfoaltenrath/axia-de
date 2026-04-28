#!/bin/sh
set -eu

prefix="${AXIA_PREALPHA_PREFIX:-}"
if [ -z "$prefix" ]; then
  prefix="$(mktemp -d /tmp/axia-prealpha.XXXXXX)"
fi

info() {
  printf '\n==> %s\n' "$1"
}

require_path() {
  if [ ! -e "$1" ]; then
    printf 'missing expected path: %s\n' "$1" >&2
    exit 1
  fi
}

require_executable() {
  require_path "$1"
  if [ ! -x "$1" ]; then
    printf 'expected executable path: %s\n' "$1" >&2
    exit 1
  fi
}

info "checking whitespace"
git diff --check

info "building debug"
zig build

info "running release checks"
zig build test

info "building ReleaseSafe"
zig build -Doptimize=ReleaseSafe

info "installing ReleaseSafe prefix at $prefix"
zig build -Doptimize=ReleaseSafe -p "$prefix"

info "checking installed files"
require_executable "$prefix/bin/axia-de"
require_executable "$prefix/bin/axia-panel"
require_executable "$prefix/bin/axia-dock"
require_executable "$prefix/bin/axia-launcher"
require_executable "$prefix/bin/axia-app-grid"
require_executable "$prefix/bin/axia-files"
require_executable "$prefix/bin/axia-settings"
require_executable "$prefix/bin/axia-session"
require_path "$prefix/share/wayland-sessions/axia-de.desktop"
require_path "$prefix/share/applications/axia-files.desktop"
require_path "$prefix/share/applications/axia-settings.desktop"
require_path "$prefix/share/axia-de/assets/wallpapers/axia-aurora.png"
require_path "$prefix/share/doc/axia-de/smoke-test.md"
require_path "$prefix/share/doc/axia-de/known-issues.md"
require_path "$prefix/share/doc/axia-de/README.md"

info "checking headless installed session"
AXIA_SESSION_CHECK_PREFIX="$prefix" scripts/session-headless-check.sh

info "pre-alpha build checks passed"
printf 'Installed prefix: %s\n' "$prefix"
printf 'Manual dogfood roteiro: docs/smoke-test.md\n'
