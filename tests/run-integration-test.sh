#!/usr/bin/env bash
# Integration test for pdf-to-images.swift.
# Generates a 5-page primary-color PDF, runs the engine in both formats,
# and asserts page count, per-page fill colors, and montage geometry.
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
ENGINE="$REPO_ROOT/pdf-to-images.swift"
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

# Expected fills, page order: red green blue yellow magenta.
EXPECTED_RGB=("255 0 0" "0 255 0" "0 0 255" "255 255 0" "255 0 255")

fail() { echo "FAIL: $*" >&2; exit 1; }

# Color comparison with per-channel tolerance.
rgb_matches() {
  # args: "r g b" "r g b" tolerance
  local a=($1) b=($2) tol=$3
  for i in 0 1 2; do
    local d=$(( ${a[$i]} - ${b[$i]} ))
    d=${d#-}
    (( d > tol )) && return 1
  done
  return 0
}

for FORMAT in jpg png; do
  echo "=== format: $FORMAT ==="
  PDF="$WORK/sample_$FORMAT.pdf"
  swift "$REPO_ROOT/tests/make-fixture.swift" "$PDF" 5 >/dev/null
  swift "$ENGINE" --format "$FORMAT" "$PDF" >/dev/null

  PAGES_DIR="$WORK/sample_${FORMAT}_pages"
  [ -d "$PAGES_DIR" ] || fail "$FORMAT: pages dir missing"

  # PNG is lossless -> tolerance 0; JPG -> small tolerance.
  if [ "$FORMAT" = png ]; then TOL=0; else TOL=24; fi

  for n in 1 2 3 4 5; do
    PAGE="$PAGES_DIR/page-$n.$FORMAT"
    [ -f "$PAGE" ] || fail "$FORMAT: $PAGE missing"
    GOT=$(swift "$REPO_ROOT/tests/check-pixels.swift" "$PAGE" | cut -d' ' -f2-)
    WANT="${EXPECTED_RGB[$((n-1))]}"
    rgb_matches "$GOT" "$WANT" "$TOL" \
      || fail "$FORMAT: page $n fill = ($GOT), expected ($WANT)"
    echo "  page $n fill ok ($GOT)"
  done

  MONTAGE="$WORK/sample_${FORMAT}_montage.$FORMAT"
  [ -f "$MONTAGE" ] || fail "$FORMAT: montage missing"
  # 5 pages -> cols=ceil(sqrt(5))=3, rows=ceil(5/3)=2. Sample cell (row0,col0)
  # center -> page 1 (red). Fractional center of top-left cell ~ (0.167, 0.25).
  CELL_RGB=$(swift "$REPO_ROOT/tests/check-pixels.swift" "$MONTAGE" 0.167 0.25 | cut -d' ' -f2-)
  rgb_matches "$CELL_RGB" "255 0 0" "$TOL" \
    || fail "$FORMAT: montage top-left cell = ($CELL_RGB), expected red"
  echo "  montage top-left cell ok ($CELL_RGB)"
done

echo "ALL INTEGRATION TESTS PASSED"
