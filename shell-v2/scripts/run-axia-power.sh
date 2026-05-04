#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
BUILD_DIR="${ROOT_DIR}/zig-out/shell-v2"
OUT_BIN="${BUILD_DIR}/axia-power"
TMP_BIN="${OUT_BIN}.$$.$RANDOM.tmp"
SOURCE_FILE="${ROOT_DIR}/shell-v2/axia-power/main.c"
STYLE_FILE="${ROOT_DIR}/shell-v2/axia-power/style.css"

mkdir -p "${BUILD_DIR}"

needs_build=0
if [[ ! -x "${OUT_BIN}" ]]; then
  needs_build=1
elif [[ "${SOURCE_FILE}" -nt "${OUT_BIN}" || "${STYLE_FILE}" -nt "${OUT_BIN}" ]]; then
  needs_build=1
fi

if [[ "${needs_build}" == "1" ]]; then
  cc \
    "${SOURCE_FILE}" \
    -o "${TMP_BIN}" \
    $(pkg-config --cflags --libs gtk4 gtk4-layer-shell-0 gdk-pixbuf-2.0)

  mv -f "${TMP_BIN}" "${OUT_BIN}"
fi

if [[ "${1:-}" == "--build-only" ]]; then
  exit 0
fi

cd "${ROOT_DIR}"
exec "${OUT_BIN}"
