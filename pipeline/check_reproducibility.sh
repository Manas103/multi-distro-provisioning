#!/bin/bash
# Rebuilds one distribution's image N times, each from a fresh qcow2 overlay on the same
# pristine base image, and diffs the resulting package manifests for byte-identical equality.
# This is the "byte-identical package manifests on N of N rebuilds" claim, measured directly
# rather than inferred from a single run.
#
# Usage: check_reproducibility.sh <ubuntu|rocky> <base_image> <n_rebuilds> <nbd_index>
set -eu
DISTRO="$1"
BASE_IMAGE="$2"
N="$3"
NBD_IDX="${4:-0}"
ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
OUT_DIR="$ROOT_DIR/images/rebuilds-$DISTRO"
mkdir -p "$OUT_DIR"

IDENTICAL=0
for i in $(seq 1 "$N"); do
  IMG="$OUT_DIR/rebuild-$i.qcow2"
  echo "=== rebuild $i/$N ($DISTRO) ==="
  bash "$ROOT_DIR/pipeline/build_image.sh" "$DISTRO" "$BASE_IMAGE" "$IMG" "$NBD_IDX"
done

echo
echo "=== comparing $N manifests ==="
FIRST="$OUT_DIR/rebuild-1.qcow2.manifest.txt"
ALL_MATCH=1
for i in $(seq 2 "$N"); do
  OTHER="$OUT_DIR/rebuild-$i.qcow2.manifest.txt"
  if cmp -s "$FIRST" "$OTHER"; then
    echo "rebuild $i: identical to rebuild 1"
  else
    echo "rebuild $i: DIFFERS from rebuild 1"
    diff "$FIRST" "$OTHER" || true
    ALL_MATCH=0
  fi
done

if [ "$ALL_MATCH" -eq 1 ]; then
  echo "RESULT: $N of $N rebuilds byte-identical"
else
  echo "RESULT: NOT all $N rebuilds were identical"
fi
sha256sum "$OUT_DIR"/*.manifest.txt
