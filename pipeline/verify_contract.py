#!/usr/bin/env python3
"""The boot-and-verify acceptance gate: SSHes into a real booted VM and checks it against the
same host-contract shape fleet-environment-check-gate uses (kernel tuning, package versions,
listening ports, systemd unit state). Reuses the contract as the promotion gate rather than
reimplementing a different one, which is also why this script's categories and check count
match that repo's exactly. Unlike that repo's simulated fleet, every fact here comes from a
real, just-booted Linux VM: no stubs.

Usage: verify_contract.py <distro: ubuntu|rocky> <contract.toml> <ssh_host> <ssh_port> <identity>
Exit code 0 if every check passes, 1 otherwise. Prints one line per failing check, naming it.
"""
import subprocess
import sys

try:
    import tomllib
except ImportError:
    import tomli as tomllib


def ssh_run(host, port, identity, script, timeout=15):
    proc = subprocess.run(
        [
            "ssh",
            "-i", identity,
            "-p", str(port),
            "-o", "StrictHostKeyChecking=no",
            "-o", "UserKnownHostsFile=/dev/null",
            "-o", "LogLevel=ERROR",
            "-o", f"ConnectTimeout={timeout}",
            "root@127.0.0.1",
            "bash", "-s",
        ],
        input=script.encode(),
        stdout=subprocess.PIPE,
        stderr=subprocess.PIPE,
        timeout=timeout + 5,
    )
    if proc.returncode != 0:
        raise RuntimeError(f"ssh failed: {proc.stderr.decode(errors='replace')}")
    return proc.stdout.decode(errors="replace")


def build_script(contract, distro):
    kernel_keys = list(contract["kernel"].keys())
    pkgs = list(contract["packages"].keys())
    units = contract["units"].keys()
    if distro == "ubuntu":
        pkg_query = "dpkg-query -W -f='${{Package}} ${{Version}}\\n' {} 2>/dev/null".format(" ".join(pkgs))
    else:
        pkg_query = "rpm -q --qf '%{{NAME}} %{{VERSION}}-%{{RELEASE}}\\n' {} 2>/dev/null".format(" ".join(pkgs))
    units_loop = "\n".join(
        f'echo "UNIT {u}"; systemctl show {u} --property=ActiveState --no-pager 2>/dev/null'
        for u in units
    )
    return f"""set -u
echo __SYSCTL__
sysctl {' '.join(kernel_keys)} 2>/dev/null
echo __PKG__
{pkg_query}
echo __PORTS__
ss -ltnH 2>/dev/null
echo __UNITS__
{units_loop}
echo __END__
"""


def parse(raw):
    sections = {"sysctl": [], "pkg": [], "ports": [], "units": []}
    cur = None
    for line in raw.splitlines():
        if line == "__SYSCTL__":
            cur = "sysctl"
        elif line == "__PKG__":
            cur = "pkg"
        elif line == "__PORTS__":
            cur = "ports"
        elif line == "__UNITS__":
            cur = "units"
        elif line == "__END__":
            cur = None
        elif cur:
            sections[cur].append(line)
    return sections


def evaluate(sections, contract):
    results = []

    actual_sysctl = {}
    for line in sections["sysctl"]:
        if "=" in line:
            k, v = line.split("=", 1)
            actual_sysctl[k.strip()] = v.strip()
    for key, expected in contract["kernel"].items():
        actual = actual_sysctl.get(key)
        results.append(("kernel", key, expected, actual, actual == expected))

    actual_pkg = {}
    for line in sections["pkg"]:
        parts = line.split(" ", 1)
        if len(parts) == 2:
            actual_pkg[parts[0].strip()] = parts[1].strip()
    for name, expected in contract["packages"].items():
        actual = actual_pkg.get(name)
        results.append(("package", name, expected, actual, actual == expected))

    listening = set()
    for line in sections["ports"]:
        cols = line.split()
        if len(cols) >= 4 and ":" in cols[3]:
            try:
                listening.add(int(cols[3].rsplit(":", 1)[1]))
            except ValueError:
                pass
    for port in contract["ports"]:
        results.append(("port", str(port), "LISTEN", "LISTEN" if port in listening else "not listening", port in listening))

    actual_units = {}
    current = None
    for line in sections["units"]:
        if line.startswith("UNIT "):
            current = line[5:].strip()
        elif line.startswith("ActiveState=") and current:
            actual_units[current] = line.split("=", 1)[1].strip()
    for unit, expected in contract["units"].items():
        actual = actual_units.get(unit)
        results.append(("systemd", unit, expected, actual, actual == expected))

    return results


def main():
    distro, contract_path, host, port, identity = sys.argv[1:6]
    with open(contract_path, "rb") as f:
        full_contract = tomllib.load(f)
    contract = full_contract[distro]

    script = build_script(contract, distro)
    raw = ssh_run(host, port, identity, script)
    sections = parse(raw)
    results = evaluate(sections, contract)

    failing = [r for r in results if not r[4]]
    for category, name, expected, actual, ok in results:
        status = "PASS" if ok else "FAIL"
        print(f"{status} {category}:{name} expected={expected!r} actual={actual!r}")

    print(f"\n{len(results) - len(failing)}/{len(results)} checks passed")
    if failing:
        print("REJECTED, failing checks:")
        for category, name, expected, actual, _ in failing:
            print(f"  - {category}:{name} expected={expected!r} actual={actual!r}")
        sys.exit(1)
    print("PROMOTED")
    sys.exit(0)


if __name__ == "__main__":
    main()
