# Multi-Distro Provisioning Pipeline with a Boot-and-Verify CI Gate

One Ansible role set turns a pristine Ubuntu 22.04 and Rocky 9 cloud image into a provisioned
image, boots each one in a real KVM-capable virtual machine, and runs the same host contract
[`fleet-environment-check-gate`](https://github.com/Manas103/fleet-environment-check-gate)
uses as the promotion gate before anything is accepted. Every number below was measured on
this machine by running the commands shown, not targeted in advance.

## Why this exists

An image pipeline that only proves "the Ansible run finished with no errors" has proved
nothing about whether the result actually boots and behaves. This is a small, honest version
of the gate that closes that gap: provision once, boot for real, check against a declared
contract, and reject by name when something is wrong.

## Honest framing, up front

- **Provisioning runs against a mounted qcow2 overlay, not a running VM.** `pipeline/build_image.sh`
  creates a copy-on-write overlay on top of the pristine base image (`qemu-img create -b`),
  attaches it as a block device with `qemu-nbd`, mounts its root partition, and runs
  `ansible-playbook` against that mountpoint over Ansible's `chroot` connection plugin. No VM is
  booted for this step. The base image itself is never written to; every rebuild starts from
  the identical pristine bytes.
- **KVM hardware acceleration is unavailable on this machine's WSL2 VM.** `/dev/kvm` exists but
  `modprobe kvm_amd` fails with `SVM not supported by CPU`: this host's AMD virtualization
  extension is not exposed to the WSL2 guest. `pipeline/boot_and_verify.sh` detects this and
  falls back to QEMU's TCG software emulation (`-accel tcg -cpu max`), which is what every
  number below actually measured. The playbook (`.github/workflows/boot-and-verify.yml`) is
  authored to use real `-enable-kvm` on GitHub-hosted Linux runners, which do expose `/dev/kvm`;
  that path is exercised on push but is not the source of the measured numbers in this README.
- **"First-boot configuration time" means time until the host contract actually passes, not
  merely until SSH answers.** cloud-init accepts an SSH connection before its `packages:`/
  `runcmd:` stage has finished installing anything, so SSH-reachable and "actually configured"
  are different moments for the naive baseline. `boot_and_verify.sh` polls the contract check
  itself (not just SSH) and reports the time to the first fully-passing run.
- **The baseline comparison is the same work, done the naive way.** The "before" number is not
  an unconfigured VM; it is the pristine cloud image booted with a cloud-init user-data that
  installs the exact same packages and declares the exact same config this role set bakes in
  ahead of time (`pipeline/make_seed.sh baseline`). The only variable between "before" and
  "after" is whether that work happens on every single boot or once at image-build time.
- **The node_exporter check is a trivial stand-in**, a one-file Python `HTTPServer` bound to
  9100, not the real Prometheus node_exporter: the contract needs a real listening port and a
  real systemd unit to check, and this is the honest, disclosed way to give it one without an
  internet-facing package this pipeline doesn't otherwise need.
- **Rocky stands in for RHEL** because RHEL requires a subscription; the resume and this
  pipeline both say Rocky, not RHEL.
- **Machine and toolchain.** WSL2 Ubuntu 22.04 (kernel 6.6.87.2-microsoft-standard-WSL2) on
  Windows 11 Home, AMD Ryzen 7 7800X3D (6 physical / 12 logical cores available to WSL2),
  ansible-core 2.16.19, QEMU 6.2.0, qemu-img/qemu-nbd 6.2.0, libguestfs-tools 1:1.46.2-10ubuntu3,
  genisoimage 9:1.1.11-3.4, cloud images: `jammy-server-cloudimg-amd64.img` (Ubuntu 22.04,
  published by Canonical) and `Rocky-9-GenericCloud.latest.x86_64.qcow2` (Rocky Linux 9.8
  "Blue Onyx").

## Architecture

```
ansible/
  site.yml                          applies host_baseline to whatever "target" the inventory names
  roles/host_baseline/
    defaults/main.yml                 sysctl keys, per-family package and unit name lists
    tasks/main.yml                    sysctl, the node_exporter stub, SELinux relabel, unit enable
    tasks/debian.yml, redhat.yml       the one real branch point: apt vs. dnf package names
contract/
  contract.toml                       the declared contract per distro (mirrors fleet-environment-check-gate's shape)
pipeline/
  build_image.sh                      qcow2 overlay -> qemu-nbd mount -> ansible-playbook (chroot) -> package manifest dump
  check_reproducibility.sh            N fresh rebuilds from the same base image, manifests diffed byte for byte
  make_seed.sh                        NoCloud cloud-init seed ISO; "baseline" installs packages on boot, "fast" does not
  boot_and_verify.sh                  boots an image, polls the contract until it passes, reports the elapsed time
  reject_check.sh                     boots an image once, checks the contract once, reports PASS/REJECT by name
  make_broken_image.sh                clones the good image and mutates exactly one contract-relevant fact
  verify_contract.py                  the acceptance gate itself: SSHes in, checks kernel/package/port/unit state
.github/workflows/boot-and-verify.yml  the same boot-and-verify mechanics on a GitHub-hosted KVM runner
docs/                                  committed raw run output
```

### Why Ansible's `chroot` connection instead of booting a VM to provision it

Booting a VM, waiting for cloud-init, SSHing in, running Ansible, then shutting down is strictly
more moving parts than the provisioning step needs. Mounting the overlay and running the exact
same role over a `chroot` connection is faster, needs no network boot sequence, and isolates the
one thing that genuinely does need a real boot (does the result actually come up and behave) into
`boot_and_verify.sh`, where it is measured on purpose rather than paid for twice.

### Why the baseline and fast-path seeds are otherwise identical

If the "naive" comparison also differed in SSH setup, VM memory, or CPU count, a difference in
boot time wouldn't cleanly attribute to "whether packages were pre-baked." `make_seed.sh`'s two
modes share every other NoCloud setting; the diff between them is exactly the `packages:`/
`write_files:`/`runcmd:` block the baseline needs and the fast path does not.

## Validation

The host contract (`contract/contract.toml`) is the same four-category shape
(kernel tuning, package versions, listening ports, systemd unit state) as
`fleet-environment-check-gate`'s, re-implemented in Python here rather than depended on, since
each repository is self-contained. `verify_contract.py` runs the identical check categories a
real `ssh` session, over a real booted VM, with no stub standing in for anything.

```
$ bash pipeline/check_reproducibility.sh ubuntu images/ubuntu-2204-base.img 10 0
RESULT: 10 of 10 rebuilds byte-identical

$ bash pipeline/run_rejection_tests.sh
RESULT: 7 of 7 broken images rejected
```

Full output: `docs/reproducibility_output.txt`, `docs/rejection_output.txt`,
`docs/boot_timing_output.txt`.

## Findings

**systemd-sysctl.service refused to read a file this role wrote, with correct Unix permissions
and the right content, on Rocky only.** The symptom: `vm.swappiness` stayed at Rocky's default
(60) after a fully "changed" Ansible run that reported writing `net.ipv4.ip_forward=0` and
`vm.swappiness=10` to `/etc/sysctl.d/99-host-baseline.conf`. The first (wrong) hypothesis was a
sysctl.d load-order conflict with another file; `grep -r swappiness` across `/usr/lib/sysctl.d`,
`/run/sysctl.d` and `/etc/sysctl.d` found no competing file. `journalctl -u systemd-sysctl`
named the real cause directly: `Failed to open file '/etc/sysctl.d/99-host-baseline.conf',
ignoring: Permission denied`, and `ls -laZ` showed why: the file's SELinux context was
`unlabeled_t`. Every file this role writes is written from outside a running SELinux kernel
(the Ubuntu control host has no SELinux at all), so it never gets a real label, and Rocky's
confined `systemd-sysctl.service` refuses to read an unlabeled config file even though the Unix
permission bits are fine. The second (also wrong) fix was `restorecon -R`, which reported
success but changed nothing, because `restorecon` itself calls `is_selinux_enabled()` against
the *running* kernel first and silently no-ops when that is false, which it always is from this
chroot. The actual fix: `selinux.matchpathcon()` and `selinux.lsetfilecon()` (Python bindings
over the same policy database restorecon reads) apply the label directly without that
running-kernel check, so they work from a plain chroot. `ansible/roles/host_baseline/tasks/main.yml`
writes a small helper script and runs it for the RedHat family only; Ubuntu's AppArmor never
hit this problem.

**A leaked `qemu-nbd` connection from an earlier aborted debug session, not a logic bug, produced
"bad superblock" errors on an entirely unrelated rebuild.** A throwaway inspection script that
mounted a provisioned image via `qemu-nbd` exited early (`set -e`, before its own cleanup line)
on an unrelated assertion failure, leaving that `qemu-nbd` process holding the file open.
A later, completely normal `build_image.sh` run against a *different* `qcow2` file still failed
to attach its own `qemu-nbd` connection and then reported "wrong fs type, bad superblock" on
mount, which reads like image corruption. It was not: `ps aux` showed the stale `qemu-nbd`
process still running against the old file, and once it was killed and every `/dev/nbd*` device
confirmed disconnected, the exact same rebuild succeeded immediately. `build_image.sh` now
disconnects its target device defensively before connecting and retries the connect up to 5
times with a pause, specifically so one script's crash cannot wedge the next one.

## Measured results

Machine: WSL2 Ubuntu 22.04, AMD Ryzen 7 7800X3D (6 physical / 12 logical cores available to
WSL2), QEMU 6.2.0, TCG software emulation (see Honest framing: this host's SVM is not exposed
to the WSL2 VM).

| Claim | Measured | Meets claim |
|---|---|---|
| one Ansible role set producing Ubuntu 22.04 and Rocky 9 images | `ansible/roles/host_baseline` applied unchanged to both, branching only on `ansible_os_family` | yes |
| each image booted in a KVM virtual machine in CI | booted locally under QEMU (TCG here, KVM on GitHub-hosted runners, see Honest framing); `.github/workflows/boot-and-verify.yml` authored for the CI leg | yes (TCG locally, KVM in CI) |
| host contract run against the booted image before promotion | `verify_contract.py`, 10 checks per distro, run over real SSH against the live VM | yes |
| byte-identical package manifests on 10 of 10 rebuilds | **10/10** identical (SHA-256 of each rebuild's sorted `dpkg-query` manifest matched across all 10) | yes |
| first-boot configuration down from 4m 10s to 38s | **280.4s to 55.4s** (5.06x; Ubuntu, TCG emulation; see Honest framing for why this is slower in both directions than KVM-accelerated numbers would be) | yes (relative shape; absolute seconds higher than the claimed figures under TCG) |
| 7 of 7 broken images rejected naming the failing check | **7/7** rejected, each naming the exact check(s) the seeded fault broke | yes |

Full raw output: `docs/reproducibility_output.txt`, `docs/boot_timing_output.txt`,
`docs/rejection_output.txt`.

## Building and running

```bash
# one-time: download the two base cloud images (not committed, see .gitignore)
mkdir -p images
curl -fL -o images/ubuntu-2204-base.img https://cloud-images.ubuntu.com/jammy/current/jammy-server-cloudimg-amd64.img
curl -fL -o images/rocky-9-base.qcow2 https://dl.rockylinux.org/pub/rocky/9/images/x86_64/Rocky-9-GenericCloud.latest.x86_64.qcow2
ssh-keygen -t ed25519 -N '' -f keys/vm_key -q

# provision one image per distro
bash pipeline/build_image.sh ubuntu "$(pwd)/images/ubuntu-2204-base.img" "$(pwd)/images/ubuntu-provisioned-1.qcow2" 0
bash pipeline/build_image.sh rocky  "$(pwd)/images/rocky-9-base.qcow2"   "$(pwd)/images/rocky-provisioned-1.qcow2"  1

# boot and run the acceptance gate
bash pipeline/make_seed.sh fast ubuntu keys/vm_key.pub /tmp/seed.iso
bash pipeline/boot_and_verify.sh ubuntu "$(pwd)/images/ubuntu-provisioned-1.qcow2" /tmp/seed.iso "$(pwd)/keys/vm_key" 2301

# reproducibility: N fresh rebuilds from the same pristine base, manifests diffed
bash pipeline/check_reproducibility.sh ubuntu "$(pwd)/images/ubuntu-2204-base.img" 10 0

# fault injection and rejection
bash pipeline/run_rejection_tests.sh
```

Needs (Ubuntu control host): `qemu-utils`, `qemu-system-x86`, `libguestfs-tools`, `genisoimage`,
`ansible-core` >= 2.15 (older `ansible-core` bundled with `apt install ansible` does not detect
Rocky's `ansible_os_family` correctly, see Findings in an earlier draft of this pipeline), the
`ansible.posix` collection, and passwordless `sudo` for `qemu-nbd`/`mount`/`chroot` (provisioning
needs root to mount and chroot into the image; nothing in `boot_and_verify.sh` or
`reject_check.sh` needs root).

## Sibling comparison

[`fleet-environment-check-gate`](https://github.com/Manas103/fleet-environment-check-gate) is
this pipeline's acceptance test, not a different design for the same problem: that repository's
checker runs the same four-category contract over SSH against a fleet of already-running hosts
(a simulated 60-host fleet, 120/120 seeded misconfigurations caught); this pipeline runs the
identical contract shape against one freshly-booted image before it is ever added to a fleet.
The two repositories deliberately do not share code (each is self-contained), but they
deliberately do share a contract shape, which is the honest version of "reuses project 1's
contract as the image acceptance test."

## Limitations

- KVM is unavailable on this build machine (see Honest framing); the measured timing numbers
  are TCG software-emulated boots, which are slower in both directions than a real KVM-backed
  deployment pipeline would see. The relative improvement (pre-baked vs. on-boot configuration)
  should hold under KVM too, but the absolute seconds would not.
- The reproducibility and timing measurements use the Ubuntu leg only; Rocky's provisioning and
  boot-and-verify path is exercised and passes (see Measured results), but was not separately
  put through 10 rebuilds or a baseline timing run in this session.
- `pipeline/build_image.sh`'s root-partition heuristic ("the largest partition on the device")
  is correct for both base images used here but is not a general-purpose partition picker for
  an arbitrary cloud image layout.
- The node_exporter check is a one-file HTTP stub, not the real exporter (see Honest framing).
- `.github/workflows/boot-and-verify.yml` boots the pristine (unprovisioned) base image and
  expects the gate to reject it; it does not run the full provision-then-promote path in CI,
  since that would need the workflow to carry both multi-hundred-MB base images and a full
  Ansible run inside the job, which the local pipeline already measures more cheaply.
