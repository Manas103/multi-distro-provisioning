#!/bin/bash
# Provisions one distribution's image by mounting a qcow2 overlay with qemu-nbd and running
# the host_baseline Ansible role against it over Ansible's chroot connection plugin. No VM is
# booted for this step; booting happens separately in boot_and_verify.sh.
#
# Usage: build_image.sh <ubuntu|rocky> <base_image> <output_qcow2> <nbd_index>
set -eu
DISTRO="$1"
BASE_IMAGE="$2"
OUTPUT="$3"
NBD_IDX="${4:-0}"
NBD_DEV="/dev/nbd${NBD_IDX}"

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
MNT="/tmp/mdp-${DISTRO}-${NBD_IDX}"

cleanup() {
  set +e
  sync
  sudo umount "$MNT/dev" 2>/dev/null
  sudo umount "$MNT/proc" 2>/dev/null
  sudo umount "$MNT/sys" 2>/dev/null
  sync
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
qemu-img create -f qcow2 -F qcow2 -b "$BASE_IMAGE" "$OUTPUT"

sudo modprobe nbd max_part=8
sudo qemu-nbd --disconnect "$NBD_DEV" >/dev/null 2>&1 || true
sleep 1
for attempt in 1 2 3 4 5; do
  if sudo qemu-nbd --connect="$NBD_DEV" "$OUTPUT"; then
    break
  fi
  echo "qemu-nbd connect attempt $attempt failed, retrying..." >&2
  sleep 2
done
sleep 2
sudo partprobe "$NBD_DEV" || true
sleep 2

# Find the root partition: the largest partition on the device (both images ship exactly one).
PART=$(lsblk -nrpo NAME,SIZE "$NBD_DEV" | tail -n +2 | sort -k2 -h | tail -1 | awk '{print $1}')
if [ -z "$PART" ]; then
  echo "could not find a partition on $NBD_DEV" >&2
  exit 1
fi

mkdir -p "$MNT"
sudo mount "$PART" "$MNT"
sudo mount --bind /proc "$MNT/proc"
sudo mount --bind /sys "$MNT/sys"
sudo mount --bind /dev "$MNT/dev"
sudo rm -f "$MNT/etc/resolv.conf"
sudo cp /etc/resolv.conf "$MNT/etc/resolv.conf"

INVENTORY=$(mktemp)
echo "target ansible_connection=chroot ansible_host=$MNT ansible_python_interpreter=/usr/bin/python3" > "$INVENTORY"

cd "$ROOT_DIR/ansible"
sudo ansible-playbook -i "$INVENTORY" site.yml
rm -f "$INVENTORY"

# Package manifest, dumped from inside the just-provisioned chroot, before unmounting. This is
# what pipeline/check_reproducibility.sh diffs across repeated builds for the byte-identical
# manifest claim.
MANIFEST="${OUTPUT}.manifest.txt"
if [ "$DISTRO" = "ubuntu" ]; then
  sudo chroot "$MNT" dpkg-query -W -f='${Package} ${Version}\n' | sort > "$MANIFEST"
else
  sudo chroot "$MNT" rpm -qa --qf '%{NAME} %{VERSION}-%{RELEASE}\n' | sort > "$MANIFEST"
fi

echo "provisioned $OUTPUT for $DISTRO at $NBD_DEV ($PART), manifest: $MANIFEST"
