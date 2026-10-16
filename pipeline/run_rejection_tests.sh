#!/bin/bash
# Builds all 7 deliberately broken images and runs the boot-and-verify gate against each,
# recording whether it was rejected and which check(s) it named. This is the "7 of 7 broken
# images rejected naming the failing check" measurement.
set -eu
cd /home/manas/build/multi-distro-provisioning
GOOD="$(pwd)/images/ubuntu-provisioned-1.qcow2"
OUT_DIR="$(pwd)/images/broken"
mkdir -p "$OUT_DIR"
bash pipeline/make_seed.sh fast ubuntu keys/vm_key.pub /tmp/seed-fast-ubuntu.iso

REJECTED=0
TOTAL=7
for fault in 1 2 3 4 5 6 7; do
  IMG="$OUT_DIR/broken-$fault.qcow2"
  echo "=== building broken image $fault ==="
  bash pipeline/make_broken_image.sh "$fault" "$GOOD" "$IMG" 0
  PORT=$((2400 + fault))
  echo "=== booting broken image $fault on port $PORT ==="
  set +e
  OUTPUT=$(bash pipeline/reject_check.sh ubuntu "$IMG" /tmp/seed-fast-ubuntu.iso "$(pwd)/keys/vm_key" "$PORT" 120 20 2>&1)
  RESULT=$?
  set -e
  echo "$OUTPUT"
  if [ "$RESULT" -ne 0 ]; then
    REJECTED=$((REJECTED + 1))
    echo "fault $fault: REJECTED (correct)"
  else
    echo "fault $fault: PROMOTED (WRONG, this should have been rejected)"
  fi
  echo
done

echo "RESULT: $REJECTED of $TOTAL broken images rejected"
