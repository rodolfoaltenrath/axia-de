#!/bin/sh
set -eu

prefix="${AXIA_DEV_PREFIX:-/tmp/axia-dev}"
optimize="${AXIA_DEV_OPTIMIZE:-Debug}"

printf 'Installing Axia-DE dev build at %s (%s)\n' "$prefix" "$optimize"
zig build -Doptimize="$optimize" -p "$prefix"

printf '\nDev prefix ready.\n'
printf 'Start session: %s/bin/axia-session\n' "$prefix"
printf 'Restart component: AXIA_DEV_PREFIX=%s scripts/dev-restart.sh dock\n' "$prefix"
