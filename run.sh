#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")"

IMAGE="podman-dind-poc:local"

echo ">>> Building outer image (rootless, no daemon) ..."
podman build -t "$IMAGE" .

echo
echo ">>> Running nested demo — minimal flags only:"
echo "      --user podman                   (stable image's preconfigured user with subuid range for nesting)"
echo "      --device /dev/fuse              (single device, NOT --privileged)"
echo "      --security-opt label=disable    (no-op on AppArmor/Ubuntu; stops SELinux AVCs on RHEL/Fedora)"
echo "      --security-opt unmask=ALL       (restores standard /proc + /sys view for the inner runtime)"
echo "    NOT used:  --privileged | -v /var/run/docker.sock | --cap-add | --userns=host"
echo

# --user podman: the stable image has /etc/subuid and /etc/subgid entries for
#   the podman user (1:999, 1001:64535). Running the outer container as this
#   user gives the inner podman a full subuid range to use for its *own* nested
#   user namespace — avoiding the "rootless single mapping" fallback.
# --security-opt unmask=ALL: undoes podman's default path-masking (certain
#   /proc and /sys subpaths). Does NOT add Linux capabilities, mount host
#   paths, or disable seccomp — the inner runtime just needs a normal /proc,
#   /sys, and devpts view inside the outer userns.
exec podman run --rm \
  --user podman \
  --device /dev/fuse \
  --security-opt label=disable \
  --security-opt unmask=ALL \
  "$IMAGE"
