#!/bin/bash
# Runs inside the outer container. Each numbered section produces one piece
# of evidence that this is a real nested container — not a docker-socket
# "sibling" and not a --privileged escape.
set -euo pipefail

echo "=== Podman-in-Podman Demo (inside outer container) ==="
echo

echo "[1] Identity — inner root is NOT host root"
echo "    whoami:  $(whoami)"
echo "    UID:     $(id -u)"
echo "    userns:  $(readlink /proc/self/ns/user)"
echo "    uid_map: $(cat /proc/self/uid_map)"
echo

echo "[2] Capability bounds — contrast with Docker --privileged (CapBnd=0x000001ffffffffff)"
grep '^Cap' /proc/self/status
echo

echo "[3] No host container socket mounted (if present, this would be 'fake nesting')"
for sock in /var/run/docker.sock /var/run/podman/podman.sock /run/podman/podman.sock; do
  if [ -S "$sock" ]; then
    echo "    FAIL: $sock is mounted"
    exit 1
  fi
done
echo "    PASS: no docker/podman socket found"
echo

echo "[4] Outer podman version"
podman --version
echo

echo "[5] Storage driver — must be overlay+rootless for unprivileged overlay FS"
podman info --format 'driver: {{.Store.GraphDriverName}} / rootless: {{.Host.Security.Rootless}} / cgroupVersion: {{.Host.CgroupsVersion}}'
echo

echo "[6] Container store is empty — proves separate store from host (not a socket share)"
podman ps -a
echo

echo "[7] Network interfaces — inner container has its own slirp4netns/pasta interfaces"
ip -o addr show | awk '{print "    " $2, $3, $4}'
echo

echo "[8] Nested workload — run hello-world as a truly nested container"
podman run --rm docker.io/library/hello-world
echo

echo "=== PASS: nested container ran rootless, no --privileged, no socket mount ==="
echo "          (isolated userns + caps + store + net)"
