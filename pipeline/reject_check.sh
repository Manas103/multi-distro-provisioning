#!/bin/bash
# Boots one image once, waits a fixed grace period for services to settle, then runs the host
# contract exactly once and reports PASS/REJECT naming the failing check(s). Unlike
# boot_and_verify.sh (which polls until the contract passes, for the timing claim), this script
# does not retry: it is the promotion gate's actual decision for a single candidate image,
# including the ones this pipeline's fault-injection step deliberately broke.
#
# Usage: reject_check.sh <distro> <image_qcow2> <seed_iso> <identity> <ssh_port> [ssh_wait_s] [grace_s]
set -eu
DISTRO="$1"
IMAGE="$2"
SEED_ISO="$3"
IDENTITY="$4"
PORT="$5"
SSH_WAIT="${6:-120}"
GRACE="${7:-15}"
ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

QEMU_PID=""
cleanup() {
  if [ -n "$QEMU_PID" ] && kill -0 "$QEMU_PID" 2>/dev/null; then
    kill "$QEMU_PID" 2>/dev/null
    wait "$QEMU_PID" 2>/dev/null
  fi
}
trap cleanup EXIT

QEMU_LOG="/tmp/mdp-qemu-reject-${DISTRO}-${PORT}.log"
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
if ! kill -0 "$QEMU_PID" 2>/dev/null; then
  ACCEL="tcg"
  launch_qemu
fi

START=$(date +%s.%N)
READY=0
while :; do
  NOW=$(date +%s.%N)
  ELAPSED=$(echo "$NOW - $START" | bc)
  if (( $(echo "$ELAPSED > $SSH_WAIT" | bc) )); then
    break
  fi
  if ssh -i "$IDENTITY" -p "$PORT" -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null \
      -o ConnectTimeout=1 -o BatchMode=yes root@127.0.0.1 true 2>/dev/null; then
    READY=1
    break
  fi
  sleep 0.5
done

if [ "$READY" -ne 1 ]; then
  echo "REJECT (host never became reachable within ${SSH_WAIT}s)"
  exit 1
fi

sleep "$GRACE"
python3 "$ROOT_DIR/pipeline/verify_contract.py" "$DISTRO" "$ROOT_DIR/contract/contract.toml" 127.0.0.1 "$PORT" "$IDENTITY"
