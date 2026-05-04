#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
BUILD_DIR="${ROOT_DIR}/zig-out/shell-v2"
GEN_DIR="${BUILD_DIR}/generated"
OUT_BIN="${BUILD_DIR}/axia-shell-v2"
TMP_BIN="${OUT_BIN}.$$.$RANDOM.tmp"
EXT_WORKSPACE_XML="/usr/share/wayland-protocols/staging/ext-workspace/ext-workspace-v1.xml"
XDG_ACTIVATION_XML="/usr/share/wayland-protocols/staging/xdg-activation/xdg-activation-v1.xml"
FOREIGN_TOPLEVEL_XML="${BUILD_DIR}/wlr-foreign-toplevel-management-unstable-v1.xml"

mkdir -p "${BUILD_DIR}" "${GEN_DIR}"

if [[ ! -f "${EXT_WORKSPACE_XML}" ]]; then
  echo "missing ext-workspace protocol XML at ${EXT_WORKSPACE_XML}" >&2
  exit 1
fi

if [[ ! -f "${XDG_ACTIVATION_XML}" ]]; then
  echo "missing xdg-activation protocol XML at ${XDG_ACTIVATION_XML}" >&2
  exit 1
fi

if [[ ! -f "${FOREIGN_TOPLEVEL_XML}" ]]; then
  curl -L --fail --silent \
    https://raw.githubusercontent.com/swaywm/wlr-protocols/master/unstable/wlr-foreign-toplevel-management-unstable-v1.xml \
    -o "${FOREIGN_TOPLEVEL_XML}"
fi

wayland-scanner client-header \
  "${EXT_WORKSPACE_XML}" \
  "${GEN_DIR}/ext-workspace-v1-client-protocol.h"

wayland-scanner private-code \
  "${EXT_WORKSPACE_XML}" \
  "${GEN_DIR}/ext-workspace-v1-protocol.c"

wayland-scanner client-header \
  "${XDG_ACTIVATION_XML}" \
  "${GEN_DIR}/xdg-activation-v1-client-protocol.h"

wayland-scanner private-code \
  "${XDG_ACTIVATION_XML}" \
  "${GEN_DIR}/xdg-activation-v1-protocol.c"

wayland-scanner client-header \
  "${FOREIGN_TOPLEVEL_XML}" \
  "${GEN_DIR}/wlr-foreign-toplevel-management-unstable-v1-client-protocol.h"

wayland-scanner private-code \
  "${FOREIGN_TOPLEVEL_XML}" \
  "${GEN_DIR}/wlr-foreign-toplevel-management-unstable-v1-protocol.c"

cc \
  "${ROOT_DIR}/shell-v2/axia-shell/main.c" \
  "${GEN_DIR}/ext-workspace-v1-protocol.c" \
  "${GEN_DIR}/xdg-activation-v1-protocol.c" \
  "${GEN_DIR}/wlr-foreign-toplevel-management-unstable-v1-protocol.c" \
  -I"${GEN_DIR}" \
  -o "${TMP_BIN}" \
  $(pkg-config --cflags --libs gtk4 gtk4-layer-shell-0 gio-unix-2.0 wayland-client)

mv -f "${TMP_BIN}" "${OUT_BIN}"

cd "${ROOT_DIR}"
exec "${OUT_BIN}"
