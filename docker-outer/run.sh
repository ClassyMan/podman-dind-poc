#!/bin/bash
# Build a Docker image containing rootless podman, then use Docker as the
# outer runtime to run a truly nested container via inner podman.
#
# Aimed at CI setups (Jenkins, GitLab agents, etc.) where the entire test
# run is wrapped in a Docker container and the test workload needs to spawn
# further containers — traditionally done with Docker-in-Docker (--privileged)
# or a host socket mount, both of which give up isolation.
set -euo pipefail
cd "$(dirname "$0")/.."

IMAGE="podman-in-docker:local"
AA_PROFILE="podman-nested"

# Ubuntu 24.04+ hosts set kernel.apparmor_restrict_unprivileged_userns=1, which
# requires processes to be under an AppArmor profile that grants 'userns' before
# they can do the uid_map writes that rootless podman needs.
if [ -r /proc/sys/kernel/apparmor_restrict_unprivileged_userns ] \
   && [ "$(cat /proc/sys/kernel/apparmor_restrict_unprivileged_userns)" = "1" ] \
   && [ ! -f "/etc/apparmor.d/$AA_PROFILE" ]; then
  echo "ERROR: kernel.apparmor_restrict_unprivileged_userns=1 on this host, but the"
  echo "       '$AA_PROFILE' AppArmor profile is not installed. Load it once with:"
  echo
  echo "         sudo install -m 0644 $(dirname "$0")/apparmor-profile/podman-nested.apparmor \\"
  echo "           /etc/apparmor.d/$AA_PROFILE"
  echo "         sudo apparmor_parser -r /etc/apparmor.d/$AA_PROFILE"
  echo
  echo "       See apparmor-profile/podman-nested.apparmor for rationale."
  exit 1
fi

echo ">>> Building outer Docker image (FROM ubuntu:24.04, apt-install podman) ..."
docker build -t "$IMAGE" -f docker-outer/Containerfile .

echo
echo ">>> Running nested demo — Docker is the outer container runtime:"
echo "      --device /dev/fuse                     (for fuse-overlayfs inside inner container)"
echo "      --device /dev/net/tun                  (for slirp4netns userspace networking inside)"
echo "      --cap-add=SYS_ADMIN                    (so setuid newuidmap can write uid_map;"
echo "                                              the container still runs as UID 1000 with CapEff=0)"
echo "      --security-opt apparmor=$AA_PROFILE  (minimal 4-line profile; see apparmor-profile/)"
echo "      --security-opt seccomp=unconfined      (Docker's default seccomp blocks some unshare/mount syscalls)"
echo "      --security-opt systempaths=unconfined  (restores /proc + /sys view for the inner runtime)"
echo "    NOT used:  --privileged | -v /var/run/docker.sock | --userns=host"
echo
echo "    (--privileged adds ~38 caps including SYS_MODULE, SYS_RAWIO, NET_ADMIN,"
echo "     disables seccomp, exposes all host devices, unmasks all paths.)"
echo

# --cap-add=SYS_ADMIN: Docker's default cap bounding set excludes CAP_SYS_ADMIN.
# The kernel's uid_map write path requires CAP_SYS_ADMIN in the target userns,
# and setuid-root newuidmap cannot exercise a cap that is excluded from the
# container's bounding set. SYS_ADMIN in *this* container: (a) the ubuntu user
# is non-root with CapEff=0, so this cap is only usable by setuid binaries
# (newuidmap, newgidmap, mount); (b) seccomp and AppArmor's other restrictions
# still apply to non-setuid processes. It is one cap vs Docker --privileged's
# ~38 caps.
exec docker run --rm \
  --device /dev/fuse \
  --device /dev/net/tun \
  --cap-add=SYS_ADMIN \
  --security-opt apparmor="$AA_PROFILE" \
  --security-opt seccomp=unconfined \
  --security-opt systempaths=unconfined \
  "$IMAGE"
