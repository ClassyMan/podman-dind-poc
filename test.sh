#!/bin/bash
# Run the Testcontainers demo and assert it actually worked. Grep for the
# Maven surefire summary line and for the container-runtime context block the
# entrypoint prints. Exit 0 on success, 1 on failure. Suitable for CI.
set -uo pipefail
cd "$(dirname "$0")"

log=$(mktemp)
trap "rm -f '$log'" EXIT

if ! command -v docker >/dev/null 2>&1; then
  echo "SKIP: docker is not on \$PATH"
  exit 2
fi

echo ">>> Running ./run.sh ..."
if ! ./run.sh >"$log" 2>&1; then
  rc=$?
  echo "FAIL (run.sh exit $rc)"
  echo "--- last 60 lines of log ---"
  tail -60 "$log"
  exit 1
fi

# Maven surefire summary: "Tests run: N, Failures: 0, Errors: 0"
if ! grep -qE 'Tests run: [1-9][0-9]*, Failures: 0, Errors: 0' "$log"; then
  echo "FAIL (no 'Tests run: N, Failures: 0, Errors: 0' line from surefire)"
  tail -60 "$log"
  exit 1
fi

# Sanity: CapBnd echoed by entrypoint must not be --privileged's full set.
if grep -qE 'CapBnd:[[:space:]]+000001ffffffffff' "$log"; then
  echo "FAIL (CapBnd matches --privileged — the isolation claim is violated)"
  exit 1
fi

echo "PASS"
exit 0
