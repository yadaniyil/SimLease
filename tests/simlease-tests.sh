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
