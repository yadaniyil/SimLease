#!/usr/bin/env bash
set -euo pipefail

PROJECT_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
LEASE_TOOL="${PROJECT_ROOT}/bin/simlease"
TEST_ROOT="$(mktemp -d "${TMPDIR:-/tmp}/simlease-tests.XXXXXX")"
export SIMLEASE_DIR="${TEST_ROOT}/leases"
export SIMLEASE_DEVICES=$'11111111-1111-1111-1111-111111111111\tiPhone Test One\n22222222-2222-2222-2222-222222222222\tiPhone Test Two'
export SIMLEASE_SERVE_SIM_STATE_DIR="${TEST_ROOT}/serve-sim"
mkdir -p "$SIMLEASE_SERVE_SIM_STATE_DIR"

# macOS /bin/bash 3.2 ignores `set -e` when `[[ ... ]]` fails, so every
# assertion fails explicitly: `[[ ... ]] || fail 'message'`.
fail() {
    printf 'simlease test failed (line %s): %s\n' "${BASH_LINENO[0]}" "$*" >&2
    exit 1
}

TOKEN_A=""
TOKEN_B=""
TOKEN_C=""

cleanup() {
    [[ -z "$TOKEN_A" ]] || "$LEASE_TOOL" release --token "$TOKEN_A" >/dev/null 2>&1 || true
    [[ -z "$TOKEN_B" ]] || "$LEASE_TOOL" release --token "$TOKEN_B" >/dev/null 2>&1 || true
    [[ -z "$TOKEN_C" ]] || "$LEASE_TOOL" release --token "$TOKEN_C" >/dev/null 2>&1 || true
    rm -rf "$TEST_ROOT"
}
trap cleanup EXIT

BOUNDARY_ROOT="${TEST_ROOT}/process-boundary"
BOUNDARY_DEVICE=$'66666666-6666-6666-6666-666666666666\tiPhone Tool Boundary'
BOUNDARY_JSON="${BOUNDARY_ROOT}/lease.json"
mkdir -p "$BOUNDARY_ROOT"
python3 - "$LEASE_TOOL" "$BOUNDARY_ROOT" "$BOUNDARY_DEVICE" "$BOUNDARY_JSON" <<'PY'
import os
import signal
import subprocess
import sys
from pathlib import Path

lease_tool, lease_root, devices, output_path = sys.argv[1:]
environment = os.environ | {"SIMLEASE_DIR": lease_root, "SIMLEASE_DEVICES": devices}
acquire = subprocess.Popen(
    [lease_tool, "acquire", "--owner", "tool-boundary", "--ttl", "60", "--json"],
    stdout=subprocess.PIPE,
    stderr=subprocess.PIPE,
    text=True,
    env=environment,
    start_new_session=True,
)
try:
    stdout, stderr = acquire.communicate(timeout=15)
except subprocess.TimeoutExpired:
    os.killpg(acquire.pid, signal.SIGKILL)
    acquire.wait()
    raise
if acquire.returncode != 0:
    raise SystemExit(f"boundary acquire failed: {stderr}")
Path(output_path).write_text(stdout)
try:
    os.killpg(acquire.pid, signal.SIGTERM)
except ProcessLookupError:
    pass
PY
BOUNDARY_TOKEN="$(jq -r '.token' "$BOUNDARY_JSON")"
SIMLEASE_DIR="$BOUNDARY_ROOT" SIMLEASE_DEVICES="$BOUNDARY_DEVICE" \
    "$LEASE_TOOL" exec --token "$BOUNDARY_TOKEN" -- true
SIMLEASE_DIR="$BOUNDARY_ROOT" SIMLEASE_DEVICES="$BOUNDARY_DEVICE" \
    "$LEASE_TOOL" release --token "$BOUNDARY_TOKEN" >/dev/null

SCALING_ROOT="${TEST_ROOT}/scaling"
SCALING_STATE="${SCALING_ROOT}/device-state"
SCALING_DEVICES=$'44444444-4444-4444-4444-444444444444\tiPhone Already Running'
SCALING_SHUTDOWN=$'55555555-5555-5555-5555-555555555555\tiPhone On Demand'
SCALING_BOOTED_UDID='55555555-5555-5555-5555-555555555555'

(
    export SIMLEASE_DIR="${SCALING_ROOT}/leases"
    export SIMLEASE_DEVICES="$SCALING_DEVICES"
    export SIMLEASE_SHUTDOWN_DEVICES="$SCALING_SHUTDOWN"
    export SIMLEASE_TEST_DEVICE_STATE_DIR="$SCALING_STATE"
    export SIMLEASE_TEST_TOTAL_MEMORY_MB=32768
    export SIMLEASE_TEST_FREE_MEMORY_PERCENT=50
    export SIMLEASE_MAX_BOOTED_SIMULATORS=2
    mkdir -p "$SCALING_STATE"
    BASE_TOKEN=''
    STARTED_TOKEN=''
    trap '[[ -z "$STARTED_TOKEN" ]] || "$LEASE_TOOL" release --token "$STARTED_TOKEN" >/dev/null 2>&1 || true; [[ -z "$BASE_TOKEN" ]] || "$LEASE_TOOL" release --token "$BASE_TOKEN" >/dev/null 2>&1 || true' EXIT

    BASE_LEASE="$("$LEASE_TOOL" acquire --owner pool-holder --ttl 60 --json)"
    BASE_TOKEN="$(jq -r '.token' <<< "$BASE_LEASE")"

    STARTED_LEASE="$("$LEASE_TOOL" acquire --owner scaler --ttl 60 --boot-if-needed --json)"
    STARTED_TOKEN="$(jq -r '.token' <<< "$STARTED_LEASE")"
    [[ "$(jq -r '.bootedBySimLease' <<< "$STARTED_LEASE")" == 'true' ]] || fail 'scaler lease did not boot a Simulator'
    [[ -f "${SCALING_STATE}/${SCALING_BOOTED_UDID}.booted" ]] || fail 'on-demand Simulator is not booted'
    RELEASED="$("$LEASE_TOOL" release --token "$STARTED_TOKEN" --json)"
    STARTED_TOKEN=''
    [[ "$(jq -r '.shutDown' <<< "$RELEASED")" == 'true' ]] || fail 'releasing the scaler lease did not shut its Simulator down'
    [[ ! -f "${SCALING_STATE}/${SCALING_BOOTED_UDID}.booted" ]] || fail 'on-demand Simulator still booted after release'

    # A boot slower than the 5-second acknowledgement window must not drop the lease.
    SLOW_LEASE="$(SIMLEASE_TEST_BOOT_DELAY_SECONDS=7 "$LEASE_TOOL" acquire --owner slow-scaler --ttl 60 --boot-if-needed --json)"
    STARTED_TOKEN="$(jq -r '.token' <<< "$SLOW_LEASE")"
    [[ "$(jq -r '.bootedBySimLease' <<< "$SLOW_LEASE")" == 'true' ]] || fail 'slow lease did not boot a Simulator'
    sleep 2
    [[ "$("$LEASE_TOOL" status --json | jq -r --arg udid "$SCALING_BOOTED_UDID" '.devices[] | select(.udid == $udid) | .lease.owner')" == 'slow-scaler' ]] || fail 'slow boot dropped the slow-scaler lease'
    "$LEASE_TOOL" exec --token "$STARTED_TOKEN" -- true
    "$LEASE_TOOL" release --token "$STARTED_TOKEN" >/dev/null
    STARTED_TOKEN=''
    [[ ! -f "${SCALING_STATE}/${SCALING_BOOTED_UDID}.booted" ]] || fail 'on-demand Simulator still booted after slow lease release'

    EXPIRING_LEASE="$("$LEASE_TOOL" acquire --owner expiry-scaler --ttl 2 --boot-if-needed --json)"
    [[ "$(jq -r '.bootedBySimLease' <<< "$EXPIRING_LEASE")" == 'true' ]] || fail 'expiring lease did not boot a Simulator'
    sleep 3
    [[ ! -f "${SCALING_STATE}/${SCALING_BOOTED_UDID}.booted" ]] || fail 'on-demand Simulator still booted after lease expiry'

    CRASHED_LEASE="$("$LEASE_TOOL" acquire --owner crash-scaler --ttl 60 --boot-if-needed --json)"
    [[ "$(jq -r '.bootedBySimLease' <<< "$CRASHED_LEASE")" == 'true' ]] || fail 'crash lease did not boot a Simulator'
    CRASHED_GUARD="$("$LEASE_TOOL" status --json | jq -r --arg udid "$SCALING_BOOTED_UDID" '.devices[] | select(.udid == $udid) | .lease.guardPid')"
    kill -9 "$CRASHED_GUARD"
    sleep 1
    "$LEASE_TOOL" status --json >/dev/null
    [[ ! -f "${SCALING_STATE}/${SCALING_BOOTED_UDID}.booted" ]] || fail 'on-demand Simulator still booted after its guard crashed'

    SIMLEASE_TEST_FREE_MEMORY_PERCENT=5 \
        "$LEASE_TOOL" acquire --owner low-memory --ttl 30 --wait 1 --boot-if-needed --json \
        > "${SCALING_ROOT}/low-memory.json" 2> "${SCALING_ROOT}/low-memory.err" \
        && fail 'low-memory acquisition unexpectedly booted a Simulator'
    grep -q 'not enough free memory' "${SCALING_ROOT}/low-memory.err" || fail 'low-memory acquisition failed for the wrong reason'
    [[ ! -f "${SCALING_STATE}/${SCALING_BOOTED_UDID}.booted" ]] || fail 'low-memory acquisition booted a Simulator'

    SIMLEASE_MAX_BOOTED_SIMULATORS=1 \
        "$LEASE_TOOL" acquire --owner capped-pool --ttl 30 --wait 1 --boot-if-needed --json \
        > "${SCALING_ROOT}/capped.json" 2> "${SCALING_ROOT}/capped.err" \
        && fail 'pool-cap acquisition unexpectedly booted a Simulator'
    grep -q 'safe booted Simulator limit' "${SCALING_ROOT}/capped.err" || fail 'pool-cap acquisition failed for the wrong reason'

    "$LEASE_TOOL" release --token "$BASE_TOKEN" --json | jq -e '.shutDown == false' >/dev/null || fail 'releasing the pool holder shut down a Simulator SimLease did not boot'
    BASE_TOKEN=''
)

CONCURRENT_LEASE_DIR="${TEST_ROOT}/concurrent-leases"
SIMLEASE_DIR="$CONCURRENT_LEASE_DIR" \
SIMLEASE_DEVICES=$'33333333-3333-3333-3333-333333333333\tiPhone Contention Test' \
    "$LEASE_TOOL" acquire --owner contender-a --ttl 30 --json \
    > "${TEST_ROOT}/contender-a.json" 2>/dev/null &
PID_A=$!
SIMLEASE_DIR="$CONCURRENT_LEASE_DIR" \
SIMLEASE_DEVICES=$'33333333-3333-3333-3333-333333333333\tiPhone Contention Test' \
    "$LEASE_TOOL" acquire --owner contender-b --ttl 30 --json \
    > "${TEST_ROOT}/contender-b.json" 2>/dev/null &
PID_B=$!
set +e
wait "$PID_A"
STATUS_A=$?
wait "$PID_B"
STATUS_B=$?
set -e
[[ $(( (STATUS_A == 0 ? 1 : 0) + (STATUS_B == 0 ? 1 : 0) )) -eq 1 ]] \
    || fail "expected exactly one winner for simultaneous acquisition, got statuses ${STATUS_A} and ${STATUS_B}"
if [[ "$STATUS_A" -eq 0 ]]; then
    CONCURRENT_TOKEN="$(jq -r '.token' "${TEST_ROOT}/contender-a.json")"
else
    CONCURRENT_TOKEN="$(jq -r '.token' "${TEST_ROOT}/contender-b.json")"
fi
SIMLEASE_DIR="$CONCURRENT_LEASE_DIR" \
SIMLEASE_DEVICES=$'33333333-3333-3333-3333-333333333333\tiPhone Contention Test' \
    "$LEASE_TOOL" release --token "$CONCURRENT_TOKEN" >/dev/null

LEASE_A="$("$LEASE_TOOL" acquire --owner agent-a --purpose 'first test' --ttl 30 --json)"
TOKEN_A="$(jq -r '.token' <<<"$LEASE_A")"
UDID_A="$(jq -r '.udid' <<<"$LEASE_A")"
[[ -n "$TOKEN_A" && -n "$UDID_A" ]] || fail 'agent-a lease is missing a token or UDID'

LEASE_B="$("$LEASE_TOOL" acquire --owner agent-b --purpose 'second test' --ttl 30 --json)"
TOKEN_B="$(jq -r '.token' <<<"$LEASE_B")"
UDID_B="$(jq -r '.udid' <<<"$LEASE_B")"
[[ "$UDID_A" != "$UDID_B" ]] || fail 'agent-a and agent-b leased the same Simulator'

if "$LEASE_TOOL" acquire --owner agent-overflow --ttl 30 --json >/dev/null 2>&1; then
    fail 'third agent unexpectedly acquired one of two leased Simulators'
fi

STATUS="$("$LEASE_TOOL" status --json)"
[[ "$(jq '[.devices[] | select(.state == "leased")] | length' <<<"$STATUS")" == '2' ]] || fail 'status does not show two leased Simulators'
[[ "$(jq -r '.devices[] | select(.lease.owner == "agent-a") | .lease.purpose' <<<"$STATUS")" == 'first test' ]] || fail 'status does not show the agent-a lease purpose'

# shellcheck disable=SC2016 # Variables intentionally expand inside the leased child shell.
EXEC_OUTPUT="$("$LEASE_TOOL" exec --token "$TOKEN_A" -- sh -c 'printf "%s|%s|%s" "$SIMULATOR_UDID" "$SIMULATOR_NAME" "$DERIVED_DATA_PATH"')"
[[ "$EXEC_OUTPUT" == "$UDID_A|iPhone Test One|"* ]] || fail 'exec did not export the leased Simulator environment'

OLD_EXPIRY="$(jq -r --arg owner agent-a '.devices[] | select(.lease.owner == $owner) | .lease.expiresAtEpoch' <<<"$("$LEASE_TOOL" status --json)")"
sleep 1
NEW_EXPIRY="$("$LEASE_TOOL" renew --token "$TOKEN_A" --ttl 60 --json | jq -r '.expiresAtEpoch')"
[[ "$NEW_EXPIRY" -gt "$OLD_EXPIRY" ]] || fail 'renew did not extend the lease expiry'

if "$LEASE_TOOL" release --token not-a-real-token >/dev/null 2>&1; then
    fail 'invalid token unexpectedly released a Simulator'
fi

"$LEASE_TOOL" release --token "$TOKEN_A" >/dev/null
TOKEN_A=""
LEASE_C="$("$LEASE_TOOL" acquire --owner agent-c --purpose 'replacement test' --ttl 2 --json)"
TOKEN_C="$(jq -r '.token' <<<"$LEASE_C")"
[[ "$(jq -r '.udid' <<<"$LEASE_C")" == "$UDID_A" ]] || fail 'agent-c did not reuse the released Simulator'

sleep 3
TOKEN_C=""
STATUS_AFTER_EXPIRY="$("$LEASE_TOOL" status --json)"
[[ "$(jq -r --arg udid "$UDID_A" '.devices[] | select(.udid == $udid) | .state' <<<"$STATUS_AFTER_EXPIRY")" == 'free' ]] || fail 'expired lease did not free its Simulator'

"$LEASE_TOOL" release --token "$TOKEN_B" >/dev/null
TOKEN_B=""

jq -n \
    --argjson pid "$$" \
    --arg device "$UDID_A" \
    '{pid:$pid,device:$device,url:"http://127.0.0.1:3999"}' \
    > "${SIMLEASE_SERVE_SIM_STATE_DIR}/server-${UDID_A}.json"
SERVE_SIM_STATUS="$("$LEASE_TOOL" status --json)"
[[ "$(jq -r --arg udid "$UDID_A" '.devices[] | select(.udid == $udid) | .state' <<<"$SERVE_SIM_STATUS")" == 'free' ]] || fail 'Simulator with an idle serve-sim helper is not free'
[[ "$(jq -r --arg udid "$UDID_A" '.devices[] | select(.udid == $udid) | .serveSimActive' <<<"$SERVE_SIM_STATUS")" == 'true' ]] || fail 'status does not report the active serve-sim helper'
LEASE_C="$("$LEASE_TOOL" acquire --owner existing-helper-reuser --device "$UDID_A" --boot-if-needed --ttl 30 --json)"
TOKEN_C="$(jq -r '.token' <<<"$LEASE_C")"
[[ "$(jq -r '.bootedBySimLease' <<<"$LEASE_C")" == 'false' ]] || fail 'reusing a running serve-sim helper booted the Simulator again'
[[ "$(jq -r '.serveSimAlreadyRunning' <<<"$LEASE_C")" == 'true' ]] || fail 'acquire did not report the running serve-sim helper'
"$LEASE_TOOL" release --token "$TOKEN_C" >/dev/null
TOKEN_C=""
# The v0.2.0 migration flag remains accepted for script compatibility.
LEASE_C="$("$LEASE_TOOL" acquire --owner compatibility-check --device "$UDID_A" --allow-active-serve-sim --ttl 30 --json)"
TOKEN_C="$(jq -r '.token' <<<"$LEASE_C")"
"$LEASE_TOOL" release --token "$TOKEN_C" >/dev/null
TOKEN_C=""
rm -f "${SIMLEASE_SERVE_SIM_STATE_DIR}/server-${UDID_A}.json"

LEASE_C="$("$LEASE_TOOL" acquire --owner stale-guard-test --device "$UDID_A" --ttl 30 --json)"
TOKEN_C="$(jq -r '.token' <<<"$LEASE_C")"
GUARD_PID="$("$LEASE_TOOL" status --json | jq -r --arg udid "$UDID_A" '.devices[] | select(.udid == $udid) | .lease.guardPid')"
kill -9 "$GUARD_PID"
sleep 1
STALE_STATUS="$("$LEASE_TOOL" status --json)"
[[ "$(jq -r --arg udid "$UDID_A" '.devices[] | select(.udid == $udid) | .state' <<<"$STALE_STATUS")" == 'free' ]] || fail 'killing the lease guard did not free the Simulator'
TOKEN_C=""

printf 'simulator lease tests passed\n'
