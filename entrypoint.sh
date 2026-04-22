#!/bin/bash
# Runs inside the outer Docker container. Starts rootless podman's
# docker-compat socket, sets DOCKER_HOST so Testcontainers finds it, then runs
# `mvn test`. The Testcontainers test in src/test/java talks to podman via
# DOCKER_HOST to spawn a real postgres container and asserts a JDBC query.
set -euo pipefail

export XDG_RUNTIME_DIR=/run/user/$(id -u)
mkdir -p "$XDG_RUNTIME_DIR/podman"

echo "=== Outer-container context ==="
echo "  user:         $(whoami) (uid=$(id -u))"
grep '^Cap' /proc/self/status | sed 's/^/  /'
echo "  /dev/fuse:    $([ -c /dev/fuse ] && echo present || echo MISSING)"
echo "  /dev/net/tun: $([ -c /dev/net/tun ] && echo present || echo MISSING)"
echo

echo "=== Starting rootless Podman docker-compat socket ==="
podman system service --time=0 "unix://$XDG_RUNTIME_DIR/podman/podman.sock" &
for _ in {1..10}; do
  [ -S "$XDG_RUNTIME_DIR/podman/podman.sock" ] && break
  sleep 1
done
if [ ! -S "$XDG_RUNTIME_DIR/podman/podman.sock" ]; then
  echo "ERROR: podman socket did not appear within 10s"
  exit 1
fi
echo "  socket: $XDG_RUNTIME_DIR/podman/podman.sock"
echo

export DOCKER_HOST="unix://$XDG_RUNTIME_DIR/podman/podman.sock"
export TESTCONTAINERS_RYUK_DISABLED=true
# Testcontainers' in-Docker detection (via /.dockerenv) makes it prefer the
# Docker gateway IP over localhost. Rootless Podman's rootlessport binds on
# the Podman host's loopback (= this outer container's loopback), so force
# Testcontainers to use localhost.
export TESTCONTAINERS_HOST_OVERRIDE=localhost

echo "=== Running Maven Testcontainers tests ==="
exec mvn -B test
