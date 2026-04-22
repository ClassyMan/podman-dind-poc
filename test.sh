#!/bin/bash
# Exercises each scenario end-to-end and asserts the claim actually holds.
# Skips scenarios whose outer runtime isn't installed on the host. Exit code:
#   0 -- every runnable scenario passed
#   1 -- at least one scenario failed
#   2 -- no runnable scenario (neither podman nor docker on $PATH)
set -uo pipefail
cd "$(dirname "$0")"

PASS_BANNER='=== PASS: nested container ran rootless, no --privileged, no socket mount ==='
HELLO_MARKER='Hello from Docker!'
PRIVILEGED_CAPBND='000001ffffffffff'

assert_scenario() {
  local name="$1" script="$2" log
  log=$(mktemp)
  trap "rm -f '$log'" RETURN

  printf '[%s] running %s ... ' "$name" "$script"

  if ! "$script" >"$log" 2>&1; then
    local rc=$?
    echo "FAIL (exit $rc)"
    echo "--- last 30 lines of log ---"
    tail -30 "$log"
    echo "--- end log ---"
    return 1
  fi

  if ! grep -qF "$PASS_BANNER" "$log"; then
    echo "FAIL (ran OK but PASS banner missing — some inner-demo.sh check failed)"
    tail -30 "$log"
    return 1
  fi

  if ! grep -qF "$HELLO_MARKER" "$log"; then
    echo "FAIL (nested hello-world did not actually execute)"
    return 1
  fi

  # Sanity: if CapBnd matches Docker --privileged, the PoC's claim is violated.
  if grep -qE "CapBnd:[[:space:]]+$PRIVILEGED_CAPBND" "$log"; then
    echo "FAIL (CapBnd equals --privileged's full set — claim violated)"
    return 1
  fi

  echo "PASS"
}

ran_any=0
failed=0

if command -v podman >/dev/null 2>&1; then
  ran_any=1
  assert_scenario "podman-outer" "./run.sh" || failed=1
else
  echo "[podman-outer] SKIP (podman not on \$PATH)"
fi

if command -v docker >/dev/null 2>&1; then
  ran_any=1
  assert_scenario "docker-outer" "./docker-outer/run.sh" || failed=1
else
  echo "[docker-outer] SKIP (docker not on \$PATH)"
fi

if [ $ran_any -eq 0 ]; then
  echo "No runnable scenarios — neither podman nor docker is installed."
  exit 2
fi

exit $failed
