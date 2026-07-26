#!/usr/bin/env bash
set -euo pipefail

PROJECT_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
LEASE_TOOL="${PROJECT_ROOT}/bin/simlease"
TEST_ROOT="$(mktemp -d "${TMPDIR:-/tmp}/simlease-tests.XXXXXX")"
export SIMLEASE_DIR="${TEST_ROOT}/leases"
export SIMLEASE_DEVICES=$'11111111-1111-1111-1111-111111111111\tiPhone Test One\n22222222-2222-2222-2222-222222222222\tiPhone Test Two'
export SIMLEASE_SERVE_SIM_STATE_DIR="${TEST_ROOT}/serve-sim"
mkdir -p "$SIMLEASE_SERVE_SIM_STATE_DIR"

TOKEN_A=""
TOKEN_B=""
TOKEN_C=""

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
    [[ "$(jq -r '.bootedBySimLease' <<< "$STARTED_LEASE")" == 'true' ]]
    [[ -f "${SCALING_STATE}/${SCALING_BOOTED_UDID}.booted" ]]
    RELEASED="$("$LEASE_TOOL" release --token "$STARTED_TOKEN" --json)"
    STARTED_TOKEN=''
    [[ "$(jq -r '.shutDown' <<< "$RELEASED")" == 'true' ]]
    [[ ! -f "${SCALING_STATE}/${SCALING_BOOTED_UDID}.booted" ]]

    EXPIRING_LEASE="$("$LEASE_TOOL" acquire --owner expiry-scaler --ttl 2 --boot-if-needed --json)"
    [[ "$(jq -r '.bootedBySimLease' <<< "$EXPIRING_LEASE")" == 'true' ]]
    sleep 3
    [[ ! -f "${SCALING_STATE}/${SCALING_BOOTED_UDID}.booted" ]]

    CRASHED_LEASE="$("$LEASE_TOOL" acquire --owner crash-scaler --ttl 60 --boot-if-needed --json)"
    [[ "$(jq -r '.bootedBySimLease' <<< "$CRASHED_LEASE")" == 'true' ]]
    CRASHED_GUARD="$("$LEASE_TOOL" status --json | jq -r --arg udid "$SCALING_BOOTED_UDID" '.devices[] | select(.udid == $udid) | .lease.guardPid')"
    kill -9 "$CRASHED_GUARD"
    sleep 1
    "$LEASE_TOOL" status --json >/dev/null
    [[ ! -f "${SCALING_STATE}/${SCALING_BOOTED_UDID}.booted" ]]

    SIMLEASE_TEST_FREE_MEMORY_PERCENT=5 \
        "$LEASE_TOOL" acquire --owner low-memory --ttl 30 --wait 1 --boot-if-needed --json \
        > "${SCALING_ROOT}/low-memory.json" 2> "${SCALING_ROOT}/low-memory.err" && {
            printf 'Low-memory acquisition unexpectedly booted a Simulator\n' >&2
            exit 1
        }
    grep -q 'not enough free memory' "${SCALING_ROOT}/low-memory.err"
    [[ ! -f "${SCALING_STATE}/${SCALING_BOOTED_UDID}.booted" ]]

    SIMLEASE_MAX_BOOTED_SIMULATORS=1 \
        "$LEASE_TOOL" acquire --owner capped-pool --ttl 30 --wait 1 --boot-if-needed --json \
        > "${SCALING_ROOT}/capped.json" 2> "${SCALING_ROOT}/capped.err" && {
            printf 'Pool-cap acquisition unexpectedly booted a Simulator\n' >&2
            exit 1
        }
    grep -q 'safe booted Simulator limit' "${SCALING_ROOT}/capped.err"

    "$LEASE_TOOL" release --token "$BASE_TOKEN" --json | jq -e '.shutDown == false' >/dev/null
    BASE_TOKEN=''
)

cleanup() {
    [[ -z "$TOKEN_A" ]] || "$LEASE_TOOL" release --token "$TOKEN_A" >/dev/null 2>&1 || true
    [[ -z "$TOKEN_B" ]] || "$LEASE_TOOL" release --token "$TOKEN_B" >/dev/null 2>&1 || true
    [[ -z "$TOKEN_C" ]] || "$LEASE_TOOL" release --token "$TOKEN_C" >/dev/null 2>&1 || true
    rm -rf "$TEST_ROOT"
}
trap cleanup EXIT

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
[[ $(( (STATUS_A == 0 ? 1 : 0) + (STATUS_B == 0 ? 1 : 0) )) -eq 1 ]] || {
    printf 'Expected exactly one winner for simultaneous acquisition, got statuses %s and %s\n' "$STATUS_A" "$STATUS_B" >&2
    exit 1
}
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
[[ -n "$TOKEN_A" && -n "$UDID_A" ]]

LEASE_B="$("$LEASE_TOOL" acquire --owner agent-b --purpose 'second test' --ttl 30 --json)"
TOKEN_B="$(jq -r '.token' <<<"$LEASE_B")"
UDID_B="$(jq -r '.udid' <<<"$LEASE_B")"
[[ "$UDID_A" != "$UDID_B" ]]

if "$LEASE_TOOL" acquire --owner agent-overflow --ttl 30 --json >/dev/null 2>&1; then
    printf 'Third agent unexpectedly acquired one of two leased simulators\n' >&2
    exit 1
fi

STATUS="$("$LEASE_TOOL" status --json)"
[[ "$(jq '[.devices[] | select(.state == "leased")] | length' <<<"$STATUS")" == '2' ]]
[[ "$(jq -r '.devices[] | select(.lease.owner == "agent-a") | .lease.purpose' <<<"$STATUS")" == 'first test' ]]

# shellcheck disable=SC2016 # Variables intentionally expand inside the leased child shell.
EXEC_OUTPUT="$("$LEASE_TOOL" exec --token "$TOKEN_A" -- sh -c 'printf "%s|%s|%s" "$SIMULATOR_UDID" "$SIMULATOR_NAME" "$DERIVED_DATA_PATH"')"
[[ "$EXEC_OUTPUT" == "$UDID_A|iPhone Test One|"* ]]

OLD_EXPIRY="$(jq -r --arg owner agent-a '.devices[] | select(.lease.owner == $owner) | .lease.expiresAtEpoch' <<<"$("$LEASE_TOOL" status --json)")"
sleep 1
NEW_EXPIRY="$("$LEASE_TOOL" renew --token "$TOKEN_A" --ttl 60 --json | jq -r '.expiresAtEpoch')"
[[ "$NEW_EXPIRY" -gt "$OLD_EXPIRY" ]]

if "$LEASE_TOOL" release --token not-a-real-token >/dev/null 2>&1; then
    printf 'Invalid token unexpectedly released a simulator\n' >&2
    exit 1
fi

"$LEASE_TOOL" release --token "$TOKEN_A" >/dev/null
TOKEN_A=""
LEASE_C="$("$LEASE_TOOL" acquire --owner agent-c --purpose 'replacement test' --ttl 2 --json)"
TOKEN_C="$(jq -r '.token' <<<"$LEASE_C")"
[[ "$(jq -r '.udid' <<<"$LEASE_C")" == "$UDID_A" ]]

sleep 3
TOKEN_C=""
STATUS_AFTER_EXPIRY="$("$LEASE_TOOL" status --json)"
[[ "$(jq -r --arg udid "$UDID_A" '.devices[] | select(.udid == $udid) | .state' <<<"$STATUS_AFTER_EXPIRY")" == 'free' ]]

"$LEASE_TOOL" release --token "$TOKEN_B" >/dev/null
TOKEN_B=""

jq -n \
    --argjson pid "$$" \
    --arg device "$UDID_A" \
    '{pid:$pid,device:$device,url:"http://127.0.0.1:3999"}' \
    > "${SIMLEASE_SERVE_SIM_STATE_DIR}/server-${UDID_A}.json"
if "$LEASE_TOOL" acquire --owner unmanaged-check --device "$UDID_A" --ttl 30 --json >/dev/null 2>&1; then
    printf 'Agent unexpectedly acquired a simulator with unmanaged serve-sim activity\n' >&2
    exit 1
fi
LEASE_C="$("$LEASE_TOOL" acquire --owner migration-adopter --device "$UDID_A" --allow-active-serve-sim --ttl 30 --json)"
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
[[ "$(jq -r --arg udid "$UDID_A" '.devices[] | select(.udid == $udid) | .state' <<<"$STALE_STATUS")" == 'free' ]]
TOKEN_C=""

printf 'simulator lease tests passed\n'
