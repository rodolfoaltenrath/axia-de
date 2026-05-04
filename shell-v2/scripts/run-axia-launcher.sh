#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
BUILD_DIR="${ROOT_DIR}/zig-out/shell-v2"
OUT_BIN="${BUILD_DIR}/axia-launcher"
TMP_BIN="${OUT_BIN}.$$.$RANDOM.tmp"

mkdir -p "${BUILD_DIR}"

cc \
  "${ROOT_DIR}/shell-v2/axia-launcher/main.c" \
  -o "${TMP_BIN}" \
  $(pkg-config --cflags --libs gtk4 gio-2.0 gio-unix-2.0)

mv -f "${TMP_BIN}" "${OUT_BIN}"

cd "${ROOT_DIR}"
exec "${OUT_BIN}"
