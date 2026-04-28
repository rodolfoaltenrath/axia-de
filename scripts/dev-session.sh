#!/bin/sh
set -eu

prefix="${AXIA_DEV_PREFIX:-/tmp/axia-dev}"
optimize="${AXIA_DEV_OPTIMIZE:-Debug}"

zig build -Doptimize="$optimize" -p "$prefix"

export XDG_CURRENT_DESKTOP="${XDG_CURRENT_DESKTOP:-Axia}"
export DESKTOP_SESSION="${DESKTOP_SESSION:-axia-de}"
export AXIA_BIN_DIR="$prefix/bin"
export AXIA_ASSET_DIR="$prefix/share/axia-de/assets"

exec "$prefix/bin/axia-session" "$@"
