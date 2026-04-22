#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")"

IMAGE="podman-dind-poc:local"

echo ">>> Building outer image (rootless, no daemon) ..."
podman build -t "$IMAGE" .

echo
echo ">>> Running nested demo — minimal flags only:"
echo "      --device /dev/fuse            (single device, NOT --privileged)"
echo "      --security-opt label=disable  (no-op on AppArmor/Ubuntu; stops SELinux AVCs on RHEL/Fedora)"
echo "    NOT used:  --privileged | -v /var/run/docker.sock | --cap-add | --userns=host"
echo

exec podman run --rm \
  --device /dev/fuse \
  --security-opt label=disable \
  "$IMAGE"
