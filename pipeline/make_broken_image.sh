#!/bin/bash
# Clones the good, already-provisioned Ubuntu image and mutates exactly one contract-relevant
# fact, to prove the boot-and-verify gate rejects a broken image and names the specific check
# that caught it. Fault IDs 1-7 are used by pipeline/run_rejection_tests.sh.
#
# Usage: make_broken_image.sh <fault_id 1-7> <good_image_qcow2> <output_qcow2> <nbd_index>
set -eu
FAULT="$1"
GOOD_IMAGE="$2"
OUTPUT="$3"
NBD_IDX="${4:-0}"
NBD_DEV="/dev/nbd${NBD_IDX}"
MNT="/tmp/mdp-broken-${FAULT}"

cleanup() {
  set +e
  sync
  sudo umount "$MNT/dev" 2>/dev/null
  sudo umount "$MNT/proc" 2>/dev/null
  sudo umount "$MNT" 2>/dev/null
  sync
  sleep 0.5
  sudo qemu-nbd --disconnect "$NBD_DEV" 2>/dev/null
  sleep 0.5
  rmdir "$MNT" 2>/dev/null
  true
}
trap cleanup EXIT

rm -f "$OUTPUT"
qemu-img create -f qcow2 -F qcow2 -b "$GOOD_IMAGE" "$OUTPUT"

sudo modprobe nbd max_part=8
sudo qemu-nbd --disconnect "$NBD_DEV" >/dev/null 2>&1 || true
sleep 1
for attempt in 1 2 3 4 5; do
  if sudo qemu-nbd --connect="$NBD_DEV" "$OUTPUT"; then
    break
  fi
  sleep 2
done
sleep 2
sudo partprobe "$NBD_DEV" || true
sleep 2

mkdir -p "$MNT"
sudo mount "${NBD_DEV}p1" "$MNT"
sudo mount --bind /proc "$MNT/proc"
sudo mount --bind /dev "$MNT/dev"

case "$FAULT" in
  1) # kernel: wrong swappiness value
    EXPECT="kernel:vm.swappiness"
    sudo sed -i 's/vm.swappiness=10/vm.swappiness=99/' "$MNT/etc/sysctl.d/99-host-baseline.conf"
    ;;
  2) # kernel: wrong ip_forward value
    EXPECT="kernel:net.ipv4.ip_forward"
    sudo sed -i 's/net.ipv4.ip_forward=0/net.ipv4.ip_forward=1/' "$MNT/etc/sysctl.d/99-host-baseline.conf"
    ;;
  3) # package: chrony removed
    EXPECT="package:chrony"
    sudo chroot "$MNT" apt-get remove -y --purge chrony >/dev/null
    ;;
  4) # package: auditd removed
    EXPECT="package:auditd"
    sudo chroot "$MNT" apt-get remove -y --purge auditd >/dev/null
    ;;
  5) # systemd + port: node_exporter disabled (never starts)
    EXPECT="systemd:node_exporter, port:9100"
    sudo chroot "$MNT" systemctl disable node_exporter >/dev/null
    ;;
  6) # systemd only: chrony disabled, package left installed
    EXPECT="systemd:chrony"
    sudo chroot "$MNT" systemctl disable chrony >/dev/null
    ;;
  7) # port only: node_exporter stub moved to the wrong port, unit still enabled and running
    EXPECT="port:9100"
    sudo sed -i 's/9100/9101/' "$MNT/usr/local/bin/node-exporter-stub.py"
    ;;
  *)
    echo "unknown fault id $FAULT" >&2
    exit 1
    ;;
esac

echo "fault $FAULT applied to $OUTPUT, expect failing check(s): $EXPECT"
