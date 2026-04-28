#!/bin/sh
set -eu

prefix="${AXIA_PREALPHA_PREFIX:-/tmp/axia-prealpha-manual}"
reports_dir="${AXIA_SMOKE_REPORT_DIR:-/tmp}"
timestamp="$(date +%Y%m%d-%H%M%S)"
report="$reports_dir/axia-smoke-report-$timestamp.md"
commit="$(git rev-parse --short HEAD)"
tag_candidate="${AXIA_TAG_CANDIDATE:-v0.1.0-prealpha.1}"

AXIA_PREALPHA_PREFIX="$prefix" scripts/prealpha-check.sh

mkdir -p "$reports_dir"
cp docs/smoke-report-template.md "$report"

tmp_report="$report.tmp"
sed \
  -e "s/^Build:$/Build:/" \
  -e "s/^- commit:$/- commit: $commit/" \
  -e "s/^- tag candidata:$/- tag candidata: $tag_candidate/" \
  -e "s|^- prefixo instalado:$|- prefixo instalado: $prefix|" \
  -e "s/^- data:$/- data: $timestamp/" \
  "$report" > "$tmp_report"
mv "$tmp_report" "$report"

cat <<EOF
Manual smoke ready.

Installed session:
  $prefix/bin/axia-session

Report:
  $report

Checklist:
  docs/smoke-test.md

After the visual smoke passes, move the local tag with:
  git tag -f -a $tag_candidate -m "$tag_candidate" -m "Build pre-alpha validada apos smoke test manual." HEAD
EOF
