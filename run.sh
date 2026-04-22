#!/bin/bash
# Build a Docker image containing rootless podman + JDK + Maven + the project,
# then run it via Docker with the minimal flag set so that rootless podman
# inside can spawn Testcontainers containers for the JUnit test suite.
set -euo pipefail
cd "$(dirname "$0")"

IMAGE="podman-dind-poc:local"
AA_PROFILE="podman-nested"

# Ubuntu 24.04+ hosts set kernel.apparmor_restrict_unprivileged_userns=1, which
# requires an AppArmor profile with an explicit 'userns' grant for the uid_map
# writes rootless podman needs. Our 4-line profile is in apparmor-profile/.
if [ -r /proc/sys/kernel/apparmor_restrict_unprivileged_userns ] \
   && [ "$(cat /proc/sys/kernel/apparmor_restrict_unprivileged_userns)" = "1" ] \
   && [ ! -f "/etc/apparmor.d/$AA_PROFILE" ]; then
  echo "ERROR: kernel.apparmor_restrict_unprivileged_userns=1 on this host, but the"
  echo "       '$AA_PROFILE' AppArmor profile is not installed. Load it once with:"
  echo
  echo "         sudo install -m 0644 apparmor-profile/podman-nested.apparmor \\"
  echo "           /etc/apparmor.d/$AA_PROFILE"
  echo "         sudo apparmor_parser -r /etc/apparmor.d/$AA_PROFILE"
  echo
  echo "       See apparmor-profile/podman-nested.apparmor for rationale."
  exit 1
fi

echo ">>> Building image (ubuntu + podman + openjdk-21 + maven + project) ..."
docker build -t "$IMAGE" -f Containerfile .

echo
echo ">>> Running Testcontainers test — Docker is the outer runtime, Podman is inner:"
echo "      --device /dev/fuse                     (for fuse-overlayfs storage)"
echo "      --device /dev/net/tun                  (for slirp4netns networking)"
echo "      --cap-add=SYS_ADMIN                    (so setuid newuidmap can write uid_map)"
echo "      --security-opt apparmor=$AA_PROFILE  (4-line userns grant profile)"
echo "      --security-opt seccomp=unconfined      (Docker default blocks unshare/mount)"
echo "      --security-opt systempaths=unconfined  (restore /proc + /sys visibility)"
echo "    NOT used:  --privileged | -v /var/run/docker.sock | --userns=host"
echo

exec docker run --rm \
  --device /dev/fuse \
  --device /dev/net/tun \
  --cap-add=SYS_ADMIN \
  --security-opt apparmor="$AA_PROFILE" \
  --security-opt seccomp=unconfined \
  --security-opt systempaths=unconfined \
  "$IMAGE"
