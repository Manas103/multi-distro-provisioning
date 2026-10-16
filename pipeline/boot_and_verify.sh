#!/bin/bash
# Boots one image (KVM-accelerated when available) and measures "first-boot configuration
# time" as the time from launch until the host contract actually passes, not merely until SSH
# answers. This matters for the baseline (naive) comparison: cloud-init accepts SSH connections
# before its packages/runcmd stage has finished, so SSH-reachable and "actually configured"
# are different moments, and only the second one is the claim this pipeline makes. Prints
# "BOOT_SECONDS=<n>" for the configuration-complete time and the contract script's own
# PASS/FAIL output, then exits with the contract script's exit code (or 2 on timeout).
#
# Usage: boot_and_verify.sh <distro> <image_qcow2> <seed_iso> <identity> <ssh_port> [timeout_s]
set -eu
DISTRO="$1"
IMAGE="$2"
SEED_ISO="$3"
IDENTITY="$4"
PORT="$5"
TIMEOUT="${6:-240}"
ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

QEMU_PID=""
cleanup() {
  if [ -n "$QEMU_PID" ] && kill -0 "$QEMU_PID" 2>/dev/null; then
    kill "$QEMU_PID" 2>/dev/null
    wait "$QEMU_PID" 2>/dev/null
  fi
}
trap cleanup EXIT

QEMU_LOG="/tmp/mdp-qemu-${DISTRO}-${PORT}.log"
ACCEL="kvm"
if [ ! -w /dev/kvm ]; then
  ACCEL="tcg"
fi

launch_qemu() {
  local accel_flags
  if [ "$ACCEL" = "kvm" ]; then
    accel_flags="-enable-kvm -cpu host"
  else
    accel_flags="-accel tcg -cpu max"
  fi
  qemu-system-x86_64 \
    $accel_flags -m 1024 -smp 2 \
    -drive file="$IMAGE",format=qcow2,if=virtio,snapshot=on \
    -cdrom "$SEED_ISO" \
    -nic user,hostfwd=tcp::"$PORT"-:22,model=virtio-net-pci \
    -nographic -serial null -monitor none \
    >"$QEMU_LOG" 2>&1 &
  QEMU_PID=$!
}

launch_qemu
sleep 1
# This host's CPU does not expose SVM/VMX to the WSL2 VM, so /dev/kvm exists but is
# nonfunctional; QEMU exits immediately in that case. Fall back to TCG software emulation and
# disclose it (see README Honest framing) rather than silently measuring a different thing.
if ! kill -0 "$QEMU_PID" 2>/dev/null; then
  ACCEL="tcg"
  launch_qemu
fi
echo "ACCEL=$ACCEL"

START=$(date +%s.%N)
CONFIGURED=0
ELAPSED=0
LAST_OUTPUT=""
while :; do
  NOW=$(date +%s.%N)
  ELAPSED=$(echo "$NOW - $START" | bc)
  if (( $(echo "$ELAPSED > $TIMEOUT" | bc) )); then
    break
  fi
  if ssh -i "$IDENTITY" -p "$PORT" -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null \
      -o ConnectTimeout=1 -o BatchMode=yes root@127.0.0.1 true 2>/dev/null; then
    set +e
    LAST_OUTPUT=$(python3 "$ROOT_DIR/pipeline/verify_contract.py" "$DISTRO" "$ROOT_DIR/contract/contract.toml" 127.0.0.1 "$PORT" "$IDENTITY" 2>&1)
    RESULT=$?
    set -e
    if [ "$RESULT" -eq 0 ]; then
      CONFIGURED=1
      break
    fi
  fi
  sleep 1
done

if [ "$CONFIGURED" -ne 1 ]; then
  echo "host contract never fully passed within ${TIMEOUT}s; last check:" >&2
  echo "$LAST_OUTPUT" >&2
  exit 2
fi

echo "BOOT_SECONDS=$ELAPSED"
echo "$LAST_OUTPUT"
exit 0
