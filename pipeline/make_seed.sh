#!/bin/bash
# Builds a NoCloud cloud-init seed ISO. Both the baseline (naive) boot and this pipeline's
# provisioned-image boot use a seed, so the only variable between them is whether cloud-init
# still has to install packages and apply config on first boot, or whether that work was
# already baked into the image by pipeline/build_image.sh.
#
# Usage: make_seed.sh <mode: baseline|fast> <distro: ubuntu|rocky> <pubkey_path> <output_iso>
set -eu
MODE="$1"
DISTRO="$2"
PUBKEY_PATH="$3"
OUTPUT_ISO="$4"

WORK=$(mktemp -d)
PUBKEY=$(cat "$PUBKEY_PATH")

cat > "$WORK/meta-data" <<EOF
instance-id: mdp-${DISTRO}-${MODE}-$$
local-hostname: mdp-${DISTRO}-${MODE}
EOF

if [ "$MODE" = "baseline" ]; then
  if [ "$DISTRO" = "ubuntu" ]; then
    PACKAGES='["openssh-server", "chrony", "auditd", "python3"]'
    SSH_UNIT="ssh"
    CHRONY_UNIT="chrony"
  else
    PACKAGES='["openssh-server", "chrony", "audit", "python3"]'
    SSH_UNIT="sshd"
    CHRONY_UNIT="chronyd"
  fi
  cat > "$WORK/user-data" <<EOF
#cloud-config
ssh_pwauth: false
disable_root: false
users:
  - name: root
    ssh_authorized_keys:
      - ${PUBKEY}
packages: ${PACKAGES}
package_update: true
write_files:
  - path: /etc/sysctl.d/99-host-baseline.conf
    content: |
      net.ipv4.ip_forward=0
      vm.swappiness=10
  - path: /usr/local/bin/node-exporter-stub.py
    permissions: '0755'
    content: |
      #!/usr/bin/env python3
      import http.server
      http.server.HTTPServer(("0.0.0.0", 9100), http.server.BaseHTTPRequestHandler).serve_forever()
  - path: /etc/systemd/system/node_exporter.service
    content: |
      [Unit]
      Description=node_exporter stand-in
      After=network.target
      [Service]
      ExecStart=/usr/bin/python3 /usr/local/bin/node-exporter-stub.py
      Restart=on-failure
      [Install]
      WantedBy=multi-user.target
runcmd:
  - sysctl --system
  - systemctl daemon-reload
  - systemctl enable --now ${SSH_UNIT} ${CHRONY_UNIT} node_exporter
EOF
else
  # Fast path: the image this seed boots was already provisioned by pipeline/build_image.sh
  # (packages installed, units enabled, sysctl declared). This seed only injects the SSH key
  # cloud-init needs on every boot of a cloud image; it does no package or config work.
  cat > "$WORK/user-data" <<EOF
#cloud-config
ssh_pwauth: false
disable_root: false
users:
  - name: root
    ssh_authorized_keys:
      - ${PUBKEY}
EOF
fi

genisoimage -output "$OUTPUT_ISO" -volid cidata -joliet -rock "$WORK/user-data" "$WORK/meta-data" >/dev/null 2>&1
rm -rf "$WORK"
echo "$OUTPUT_ISO"
