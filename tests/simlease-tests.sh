#!/usr/bin/env bash
# shellcheck disable=SC2030,SC2031 # Test groups set their own environment in subshells on purpose.
set -euo pipefail

PROJECT_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
LEASE_TOOL="${PROJECT_ROOT}/bin/simlease"
TEST_ROOT="$(mktemp -d "${TMPDIR:-/tmp}/simlease-tests.XXXXXX")"
export SIMLEASE_DIR="${TEST_ROOT}/leases"
export SIMLEASE_DEVICES=$'11111111-1111-1111-1111-111111111111\tiPhone Test One\n22222222-2222-2222-2222-222222222222\tiPhone Test Two'
export SIMLEASE_SERVE_SIM_STATE_DIR="${TEST_ROOT}/serve-sim"
# Keeps the Mac's real simslim profile and pinned list out of the tests.
export SIMLEASE_CONFIG_DIR="${TEST_ROOT}/config"
# A checkout on an external volume would get DerivedData folders on that volume:
# the tests lease from a workspace inside the test folder instead.
export SIMLEASE_WORKSPACE="${TEST_ROOT}/workspace"
unset SIMLEASE_DERIVED_DATA_DIR
mkdir -p "$SIMLEASE_SERVE_SIM_STATE_DIR" "$SIMLEASE_WORKSPACE"

# macOS /bin/bash 3.2 ignores `set -e` when `[[ ... ]]` fails, so every
# assertion fails explicitly: `[[ ... ]] || fail 'message'`.
fail() {
    printf 'simlease test failed (line %s): %s\n' "${BASH_LINENO[0]}" "$*" >&2
    exit 1
}

TOKEN_A=""
TOKEN_B=""
TOKEN_C=""
# The mount point of the test disk image while it is attached.
TEST_VOLUME=""

cleanup() {
    [[ -z "$TOKEN_A" ]] || "$LEASE_TOOL" release --token "$TOKEN_A" >/dev/null 2>&1 || true
    [[ -z "$TOKEN_B" ]] || "$LEASE_TOOL" release --token "$TOKEN_B" >/dev/null 2>&1 || true
    [[ -z "$TOKEN_C" ]] || "$LEASE_TOOL" release --token "$TOKEN_C" >/dev/null 2>&1 || true
    [[ -z "$TEST_VOLUME" ]] || hdiutil detach -quiet -force "$TEST_VOLUME" >/dev/null 2>&1 || true
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

leases_owned_by() {
    "$LEASE_TOOL" status --json | jq -r --arg owner "$1" '[.devices[] | select(.lease.owner == $owner)] | length'
}

# --token-file saves the token privately and never overwrites a live lease's token.
TOKEN_FILE="${TEST_ROOT}/lease.token"
"$LEASE_TOOL" acquire --owner file-holder --ttl 3 --token-file "$TOKEN_FILE" >/dev/null
TOKEN_C="$(cat "$TOKEN_FILE")"
[[ -n "$TOKEN_C" ]] || fail '--token-file did not save the token'
[[ "$(stat -f '%Lp' "$TOKEN_FILE")" == '600' ]] || fail 'the token file is readable by others'
if "$LEASE_TOOL" acquire --owner file-clobber --ttl 3 --token-file "$TOKEN_FILE" >/dev/null 2>&1; then
    fail 'acquire overwrote a token file that still holds an active lease'
fi
[[ "$(cat "$TOKEN_FILE")" == "$TOKEN_C" ]] || fail 'the refused acquire changed the token file'

# exec renews while its command runs, so a 3 s lease outlives a 7 s command.
"$LEASE_TOOL" exec --token-file "$TOKEN_FILE" -- sleep 7 &
EXEC_PID=$!
sleep 6
[[ "$(leases_owned_by file-holder)" == '1' ]] || fail 'exec let the lease expire under a command longer than its TTL'
wait "$EXEC_PID" || fail 'exec of the long command failed'
"$LEASE_TOOL" release --token-file "$TOKEN_FILE" >/dev/null || fail 'release --token-file failed'
TOKEN_C=""
[[ "$(leases_owned_by file-holder)" == '0' ]] || fail 'release --token-file left the lease in place'

# Once the command has exited nothing renews, and the lease runs out on time.
# The file now holds a dead token, which acquire may overwrite.
"$LEASE_TOOL" acquire --owner short-exec --ttl 3 --token-file "$TOKEN_FILE" >/dev/null || fail 'acquire refused a token file holding a dead token'
TOKEN_C="$(cat "$TOKEN_FILE")"
"$LEASE_TOOL" exec --token-file "$TOKEN_FILE" -- true
sleep 5
[[ "$(leases_owned_by short-exec)" == '0' ]] || fail 'the lease kept renewing after the exec command exited'
TOKEN_C=""

# Every leased Simulator is slimmed with the shared profile plus the lease's
# --keep-services. The fake simslim remembers the last `on` per device and acts
# like simslim 0.11: an unknown category exits 1, `verify` exits 1 on a
# Simulator that isn't booted, and `on` shuts a booted Simulator down,
# reconfigures it and boots it again. With SIMLEASE_TEST_DEVICE_STATE_DIR
# unset, every Simulator counts as booted.
FAKE_SIMSLIM="${TEST_ROOT}/fake-simslim"
export FAKE_SIMSLIM_STATE="${TEST_ROOT}/fake-simslim-state"
cat > "$FAKE_SIMSLIM" <<'EOF'
#!/usr/bin/env bash
mkdir -p "$FAKE_SIMSLIM_STATE"
command="${1:-}"; udid="${2:-}"; shift 2 || shift $#
printf '%s %s %s\n' "$command" "$udid" "$*" >> "${FAKE_SIMSLIM_STATE}/calls.log"
categories=' widgets siri search icloud store pim web family health photos apps messaging connectivity '
marker="${SIMLEASE_TEST_DEVICE_STATE_DIR:-}/${udid}.booted"
is_booted() { [[ -z "${SIMLEASE_TEST_DEVICE_STATE_DIR:-}" || -f "$marker" ]]; }
known() {
    [[ "$categories" == *" $1 "* ]] && return 0
    printf 'simslim: unknown category "%s" (see `simslim profiles`)\n' "$1" >&2
    return 1
}
known_except() {
    local category
    [[ "${1:-}" == --except ]] || return 0
    for category in ${2//,/ }; do known "$category" || return 1; done
}
case "$command" in
    version) printf 'simslim %s\n' "${FAKE_SIMSLIM_VERSION:-0.11.0}" ;;
    profiles) [[ -z "$udid" ]] || known "$udid" || exit 1 ;;
    verify)
        known_except "$@" || exit 1
        is_booted || { printf 'simslim: %s is not booted\n' "$udid" >&2; exit 1; }
        [[ "$(cat "${FAKE_SIMSLIM_STATE}/${udid}" 2>/dev/null)" == "$*" ]] ;;
    on)
        known_except "$@" || exit 1
        [[ -z "${SIMLEASE_TEST_DEVICE_STATE_DIR:-}" ]] || rm -f "$marker"
        if [[ -n "${FAKE_SIMSLIM_ON_FAILS:-}" ]]; then
            printf 'simslim: shutting down %s\n' "$udid" >&2
            printf 'simslim: boot timed out after 10m0s\n' >&2
            exit 1
        fi
        printf '%s' "$*" > "${FAKE_SIMSLIM_STATE}/${udid}"
        [[ -z "${SIMLEASE_TEST_DEVICE_STATE_DIR:-}" ]] || : > "$marker" ;;
esac
EOF
chmod +x "$FAKE_SIMSLIM"
slim_acquire() {
    SIMLEASE_SIMSLIM_BIN="$FAKE_SIMSLIM" "$LEASE_TOOL" acquire --device "$UDID_A" --ttl 30 --json "$@" 2>/dev/null
}
SLIM_LEASE="$(slim_acquire --owner slim-a --keep-services widgets)"
TOKEN_C="$(jq -r '.token' <<<"$SLIM_LEASE")"
[[ "$(jq -r '.slim' <<<"$SLIM_LEASE")" == 'applied' ]] || fail 'a stock Simulator was not slimmed on acquire'
[[ "$(jq -r '.keptServices' <<<"$SLIM_LEASE")" == 'photos,store,icloud,web,widgets' ]] || fail 'kept services are not the profile plus --keep-services'
"$LEASE_TOOL" release --token "$TOKEN_C" >/dev/null
SLIM_LEASE="$(slim_acquire --owner slim-b --keep-services widgets)"
TOKEN_C="$(jq -r '.token' <<<"$SLIM_LEASE")"
[[ "$(jq -r '.slim' <<<"$SLIM_LEASE")" == 'verified' ]] || fail 'an already slim Simulator was slimmed again'
"$LEASE_TOOL" release --token "$TOKEN_C" >/dev/null
mkdir -p "$SIMLEASE_CONFIG_DIR"
printf '{"name":"shared","except":["photos","store"],"keep":["com.apple.apsd"]}\n' > "${SIMLEASE_CONFIG_DIR}/simslim-profile.json"
SLIM_LEASE="$(slim_acquire --owner slim-c)"
TOKEN_C="$(jq -r '.token' <<<"$SLIM_LEASE")"
[[ "$(jq -r '.slim' <<<"$SLIM_LEASE")" == 'applied' ]] || fail 'a changed profile did not re-slim the Simulator'
[[ "$(jq -r '.keptServices' <<<"$SLIM_LEASE")" == 'photos,store' ]] || fail 'the shared profile file was not used'
grep -q -- '--keep com.apple.apsd' "${FAKE_SIMSLIM_STATE}/calls.log" || fail 'the profile keep list was not passed to simslim'
"$LEASE_TOOL" release --token "$TOKEN_C" >/dev/null
rm -f "${SIMLEASE_CONFIG_DIR}/simslim-profile.json"
SLIM_LEASE="$(SIMLEASE_SLIM=0 slim_acquire --owner slim-off)"
TOKEN_C="$(jq -r '.token' <<<"$SLIM_LEASE")"
[[ "$(jq -r '.slim' <<<"$SLIM_LEASE")" == 'off' ]] || fail 'SIMLEASE_SLIM=0 did not turn slimming off'
"$LEASE_TOOL" release --token "$TOKEN_C" >/dev/null
TOKEN_C=""

# An unknown --keep-services category fails before any lease is taken.
set +e
SIMLEASE_SIMSLIM_BIN="$FAKE_SIMSLIM" "$LEASE_TOOL" acquire --device "$UDID_A" --owner slim-bad \
    --keep-services 'widgets, bogus' --ttl 30 --json >/dev/null 2>"${TEST_ROOT}/bad-category.err"
STATUS_BAD=$?
set -e
[[ "$STATUS_BAD" -eq 1 ]] || fail "an unknown --keep-services category exited ${STATUS_BAD}, not 1"
grep -q "unknown --keep-services category 'bogus'" "${TEST_ROOT}/bad-category.err" || fail 'an unknown category failed for the wrong reason'
[[ "$(leases_owned_by slim-bad)" == '0' ]] || fail 'an unknown --keep-services category left a lease'

# simslim older than 0.6.1 is unsupported: the lease is granted, not slimmed.
: > "${FAKE_SIMSLIM_STATE}/calls.log"
SLIM_LEASE="$(FAKE_SIMSLIM_VERSION=0.6.0 SIMLEASE_SIMSLIM_BIN="$FAKE_SIMSLIM" "$LEASE_TOOL" acquire --device "$UDID_A" \
    --owner slim-old --ttl 30 --json 2>"${TEST_ROOT}/old-simslim.err")"
TOKEN_C="$(jq -r '.token' <<<"$SLIM_LEASE")"
[[ "$(jq -r '.slim' <<<"$SLIM_LEASE")" == 'unsupported' ]] || fail 'simslim 0.6.0 was not reported as unsupported'
grep -q 'simslim 0.6.0 is too old' "${TEST_ROOT}/old-simslim.err" || fail 'an unsupported simslim gave no warning'
! grep -qE '^(verify|on) ' "${FAKE_SIMSLIM_STATE}/calls.log" || fail 'an unsupported simslim was used to slim'
"$LEASE_TOOL" release --token "$TOKEN_C" >/dev/null
TOKEN_C=""
simslim_check() {
    SIMLEASE_SIMSLIM_BIN="$FAKE_SIMSLIM" FAKE_SIMSLIM_VERSION="$1" "$LEASE_TOOL" __simslim-check 2>&1
}
[[ "$(simslim_check 0.11.0)" == 'simslim 0.11.0' ]] || fail 'the simslim check did not print the version'
grep -q '0.11 or newer slims much faster' <<<"$(simslim_check 0.10.2)" || fail 'the simslim check did not warn below 0.11'
grep -q 'simslim 0.6.0 is unsupported' <<<"$(simslim_check 0.6.0)" || fail 'the simslim check did not warn below 0.6.1'
grep -q 'could not read the version' <<<"$(simslim_check dev)" || fail 'the simslim check failed on an unreadable version'
pool_cap() {
    SIMLEASE_SIMSLIM_BIN="$FAKE_SIMSLIM" FAKE_SIMSLIM_VERSION="$1" SIMLEASE_TEST_TOTAL_MEMORY_MB=65536 \
        SIMLEASE_TEST_FREE_MEMORY_PERCENT=50 "$LEASE_TOOL" status --json | jq -r '.capacity.maxBootedSimulators'
}
[[ "$(pool_cap 0.11.0)" == '6' && "$(pool_cap 0.6.0)" == '3' ]] || fail 'an unsupported simslim still raised the pool cap'

# A failed `simslim on` keeps the lease. simslim 0.11 shuts a booted Simulator
# down first, so simlease boots it again.
SLIM_ROOT="${TEST_ROOT}/slim-state"
(
    export SIMLEASE_DIR="${SLIM_ROOT}/leases"
    export SIMLEASE_DEVICES=$'77777777-7777-7777-7777-777777777777\tiPhone Slim Listed'
    export SIMLEASE_SHUTDOWN_DEVICES=$'88888888-8888-8888-8888-888888888888\tiPhone Slim Fails'
    export SIMLEASE_TEST_DEVICE_STATE_DIR="${SLIM_ROOT}/device-state"
    export SIMLEASE_TEST_TOTAL_MEMORY_MB=32768
    export SIMLEASE_TEST_FREE_MEMORY_PERCENT=50
    export SIMLEASE_MAX_BOOTED_SIMULATORS=4
    export SIMLEASE_SIMSLIM_BIN="$FAKE_SIMSLIM"
    mkdir -p "$SIMLEASE_TEST_DEVICE_STATE_DIR"
    LISTED_UDID='77777777-7777-7777-7777-777777777777'
    FAILING_UDID='88888888-8888-8888-8888-888888888888'
    FAILING_TOKEN=''
    LISTED_TOKEN=''
    trap '[[ -z "$FAILING_TOKEN" ]] || "$LEASE_TOOL" release --token "$FAILING_TOKEN" >/dev/null 2>&1 || true; [[ -z "$LISTED_TOKEN" ]] || "$LEASE_TOOL" release --token "$LISTED_TOKEN" >/dev/null 2>&1 || true' EXIT

    FAILING_LEASE="$(FAKE_SIMSLIM_ON_FAILS=1 "$LEASE_TOOL" acquire --device "$FAILING_UDID" --boot-if-needed \
        --owner slim-fails --ttl 30 --json 2>"${SLIM_ROOT}/on-fails.err")"
    FAILING_TOKEN="$(jq -r '.token' <<<"$FAILING_LEASE")"
    [[ "$(jq -r '.slim' <<<"$FAILING_LEASE")" == 'failed' ]] || fail 'a failed simslim on was not reported as slim: failed'
    [[ -f "${SIMLEASE_TEST_DEVICE_STATE_DIR}/${FAILING_UDID}.booted" ]] || fail 'a failed simslim on left the Simulator shut down'
    grep -q 'keeps its previous profile' "${SLIM_ROOT}/on-fails.err" || fail 'a failed simslim on gave the wrong message'
    grep -q 'simslim said: simslim: boot timed out after 10m0s' "${SLIM_ROOT}/on-fails.err" || fail "simslim's last error line was not shown"
    "$LEASE_TOOL" exec --token "$FAILING_TOKEN" -- true || fail 'the lease did not survive a failed simslim on'
    "$LEASE_TOOL" release --token "$FAILING_TOKEN" >/dev/null
    FAILING_TOKEN=''

    # `verify` exits 1 on a Simulator that isn't booted (this one shut down
    # after it was listed); `on` then slims it and boots it.
    set +e
    "$FAKE_SIMSLIM" verify "$LISTED_UDID" --except photos >/dev/null 2>&1
    STATUS_VERIFY=$?
    set -e
    [[ "$STATUS_VERIFY" -eq 1 ]] || fail "verify on a Simulator that isn't booted exited ${STATUS_VERIFY}, not 1"
    LISTED_LEASE="$("$LEASE_TOOL" acquire --device "$LISTED_UDID" --owner slim-shut --ttl 30 --json 2>/dev/null)"
    LISTED_TOKEN="$(jq -r '.token' <<<"$LISTED_LEASE")"
    [[ "$(jq -r '.slim' <<<"$LISTED_LEASE")" == 'applied' ]] || fail 'a Simulator that failed verify was not slimmed'
    [[ -f "${SIMLEASE_TEST_DEVICE_STATE_DIR}/${LISTED_UDID}.booted" ]] || fail 'slimming did not leave the Simulator booted'
    "$LEASE_TOOL" release --token "$LISTED_TOKEN" >/dev/null
    LISTED_TOKEN=''
)

# Pinned Simulators are skipped by automatic picks and leased only by --device.
printf '%s   # signed in, keep\n' "$UDID_A" > "${SIMLEASE_CONFIG_DIR}/pinned"
PIN_AUTO="$("$LEASE_TOOL" acquire --owner pin-auto --ttl 30 --json)"
TOKEN_C="$(jq -r '.token' <<<"$PIN_AUTO")"
[[ "$(jq -r '.udid' <<<"$PIN_AUTO")" != "$UDID_A" ]] || fail 'an automatic pick leased a pinned Simulator'
if "$LEASE_TOOL" acquire --owner pin-auto-2 --ttl 30 --json >/dev/null 2>&1; then
    fail 'an automatic pick leased the pinned Simulator when nothing else was free'
fi
PIN_DIRECT="$("$LEASE_TOOL" acquire --owner pin-direct --device "$UDID_A" --ttl 30 --json)"
TOKEN_B="$(jq -r '.token' <<<"$PIN_DIRECT")"
[[ "$(jq -r '.udid' <<<"$PIN_DIRECT")" == "$UDID_A" ]] || fail '--device did not lease the pinned Simulator'
"$LEASE_TOOL" release --token "$TOKEN_B" >/dev/null
TOKEN_B=""
"$LEASE_TOOL" release --token "$TOKEN_C" >/dev/null
TOKEN_C=""
rm -f "${SIMLEASE_CONFIG_DIR}/pinned"

# DerivedData. A project on the boot volume keeps the path it always had. A
# project on another volume gets a folder at the root of that volume. The
# volume here is a disk image mounted at a path with a space in it.
derived_key() {
    printf '%s' "$1" | shasum -a 256 | awk '{print substr($1, 1, 12)}'
}
# Leases UDID_A from a workspace (and an optional SIMLEASE_DERIVED_DATA_DIR),
# prints the DerivedData path of the lease, and releases it. The acquire's
# stderr lands in derived.err.
leased_derived_data_path() {
    local lease
    local token
    local path
    lease="$(SIMLEASE_WORKSPACE="$1" SIMLEASE_DERIVED_DATA_DIR="${2:-}" "$LEASE_TOOL" acquire --device "$UDID_A" \
        --owner derived-data --ttl 30 --json 2>"${TEST_ROOT}/derived.err")"
    token="$(jq -r '.token' <<<"$lease")"
    # shellcheck disable=SC2016 # The variable expands inside the leased child shell.
    path="$("$LEASE_TOOL" exec --token "$token" -- sh -c 'printf "%s" "$DERIVED_DATA_PATH"')"
    "$LEASE_TOOL" release --token "$token" >/dev/null
    [[ "$path" == "$(jq -r '.derivedDataPath' <<<"$lease")" ]] || fail 'exec and acquire disagree on the DerivedData path'
    printf '%s\n' "$path"
}
# The state `prune` printed for a project.
prune_state() {
    awk -F '\t' -v project="$2" '$3 == project { print $1 }' <<<"$1"
}
DEFAULT_DERIVED_ROOT="${SIMLEASE_DIR}/derived-data"
BOOT_PROJECT="${TEST_ROOT}/boot project"
MISSING_PROJECT="${TEST_ROOT}/no such project"
mkdir -p "$BOOT_PROJECT"
[[ "$(leased_derived_data_path "$BOOT_PROJECT")" == "${DEFAULT_DERIVED_ROOT}/$(derived_key "$BOOT_PROJECT")/${UDID_A}" ]] \
    || fail 'a project on the boot volume did not keep the default DerivedData path'
! grep -q 'DerivedData' "${TEST_ROOT}/derived.err" || fail 'a project on the boot volume got a DerivedData warning'
[[ ! -e "${DEFAULT_DERIVED_ROOT}/$(derived_key "$BOOT_PROJECT")" ]] || fail 'the default DerivedData location got a folder it never had before'
[[ "$(leased_derived_data_path "$MISSING_PROJECT")" == "${DEFAULT_DERIVED_ROOT}/$(derived_key "$MISSING_PROJECT")/${UDID_A}" ]] \
    || fail 'a workspace that does not exist did not get the default DerivedData path'
"$LEASE_TOOL" prune >/dev/null 2>&1 && fail 'prune on the boot volume did not ask for --dir'

TEST_VOLUME="${TEST_ROOT}/ext vol"
mkdir -p "$TEST_VOLUME"
hdiutil create -quiet -size 4m -fs HFS+ -volname 'SimLease Test' "${TEST_ROOT}/volume.dmg"
hdiutil attach -quiet -nobrowse -mountpoint "$TEST_VOLUME" "${TEST_ROOT}/volume.dmg"
VOLUME_PROJECT="${TEST_VOLUME}/dev/app one"
VOLUME_PROJECT_TWO="${TEST_VOLUME}/dev/app two"
mkdir -p "${VOLUME_PROJECT}/ios" "$VOLUME_PROJECT_TWO"
# The lease reports the physical mount point: /var is a link to /private/var.
VOLUME_DERIVED_ROOT="$(cd "$TEST_VOLUME" && pwd -P)/simlease-derived-data"
VOLUME_KEY="$(derived_key "$VOLUME_PROJECT")"
[[ "$(leased_derived_data_path "$VOLUME_PROJECT")" == "${VOLUME_DERIVED_ROOT}/${VOLUME_KEY}/${UDID_A}" ]] \
    || fail 'a project on another volume did not get DerivedData on that volume'
! grep -q 'DerivedData' "${TEST_ROOT}/derived.err" || fail 'a writable volume gave a DerivedData warning'
[[ "$(jq -r '.project' "${VOLUME_DERIVED_ROOT}/${VOLUME_KEY}/simlease-project.json")" == "$VOLUME_PROJECT" ]] \
    || fail 'the DerivedData folder on the volume has no marker that names its project'
[[ "$(leased_derived_data_path "${VOLUME_PROJECT}/ios")" == "${VOLUME_DERIVED_ROOT}/$(derived_key "${VOLUME_PROJECT}/ios")/${UDID_A}" ]] \
    || fail 'a subfolder of a project on another volume did not use the folder at the volume root'
[[ "$(prune_state "$(SIMLEASE_WORKSPACE="$VOLUME_PROJECT" "$LEASE_TOOL" prune)" "$VOLUME_PROJECT")" == 'in-use' ]] \
    || fail 'prune did not find the DerivedData folder of the current volume'
# An emulator lease has no DerivedData: nothing of it lands on the volume.
(
    export SIMLEASE_ANDROID_TEST_STATE_DIR="${TEST_ROOT}/android-derived"
    export SIMLEASE_ANDROID_AVDS='avd_shared'
    export ANDROID_AVD_HOME="${TEST_ROOT}/avd-home"
    export SIMLEASE_MAX_EMULATORS=1
    AND_TOKEN="$(SIMLEASE_WORKSPACE="$VOLUME_PROJECT_TWO" "$LEASE_TOOL" acquire --avd avd_shared --owner and-derived --ttl 30 --json | jq -r '.token')"
    AND_PATH="$("$LEASE_TOOL" status --json | jq -r '.devices[] | select(.lease.owner == "and-derived") | .lease.derivedDataPath')"
    "$LEASE_TOOL" release --token "$AND_TOKEN" >/dev/null
    [[ "$AND_PATH" == "${DEFAULT_DERIVED_ROOT}/$(derived_key "$VOLUME_PROJECT_TWO")/emulator-"* ]] \
        || fail 'an emulator lease did not keep the default DerivedData path in its metadata'
)
[[ ! -e "${VOLUME_DERIVED_ROOT}/$(derived_key "$VOLUME_PROJECT_TWO")" ]] || fail 'an emulator lease created a DerivedData folder on the volume'

# SIMLEASE_DERIVED_DATA_DIR moves DerivedData only, for a project on any volume.
OVERRIDE_ROOT="${TEST_ROOT}/derived override"
[[ "$(leased_derived_data_path "$BOOT_PROJECT" "$OVERRIDE_ROOT")" == "${OVERRIDE_ROOT}/$(derived_key "$BOOT_PROJECT")/${UDID_A}" ]] \
    || fail 'SIMLEASE_DERIVED_DATA_DIR was not used for a project on the boot volume'
[[ "$(leased_derived_data_path "$VOLUME_PROJECT" "${OVERRIDE_ROOT}/")" == "${OVERRIDE_ROOT}/${VOLUME_KEY}/${UDID_A}" ]] \
    || fail 'SIMLEASE_DERIVED_DATA_DIR did not win over the project volume'
[[ "$(jq -r '.project' "${OVERRIDE_ROOT}/${VOLUME_KEY}/simlease-project.json")" == "$VOLUME_PROJECT" ]] \
    || fail 'the folder under SIMLEASE_DERIVED_DATA_DIR has no marker that names its project'
[[ -d "${SIMLEASE_DIR}/leases" && ! -e "${OVERRIDE_ROOT}/leases" ]] || fail 'SIMLEASE_DERIVED_DATA_DIR moved more than DerivedData'

# A folder that cannot be created or written never fails the lease: the lease
# warns and uses the default location.
: > "${TEST_ROOT}/a file"
[[ "$(leased_derived_data_path "$BOOT_PROJECT" "${TEST_ROOT}/a file/derived")" == "${DEFAULT_DERIVED_ROOT}/$(derived_key "$BOOT_PROJECT")/${UDID_A}" ]] \
    || fail 'an unusable SIMLEASE_DERIVED_DATA_DIR did not fall back to the default location'
grep -q 'cannot write DerivedData' "${TEST_ROOT}/derived.err" || fail 'an unusable SIMLEASE_DERIVED_DATA_DIR gave no warning'
[[ "$(leased_derived_data_path "$BOOT_PROJECT" 'relative/derived')" == "${DEFAULT_DERIVED_ROOT}/$(derived_key "$BOOT_PROJECT")/${UDID_A}" ]] \
    || fail 'a relative SIMLEASE_DERIVED_DATA_DIR did not fall back to the default location'
grep -q 'must be an absolute path' "${TEST_ROOT}/derived.err" || fail 'a relative SIMLEASE_DERIVED_DATA_DIR gave no warning'
hdiutil detach -quiet "$TEST_VOLUME" || hdiutil detach -quiet -force "$TEST_VOLUME"
hdiutil attach -quiet -nobrowse -readonly -mountpoint "$TEST_VOLUME" "${TEST_ROOT}/volume.dmg"
# "app one" already has a folder on the volume and "app two" has none; neither
# can be written now.
for READ_ONLY_PROJECT in "$VOLUME_PROJECT" "$VOLUME_PROJECT_TWO"; do
    [[ "$(leased_derived_data_path "$READ_ONLY_PROJECT")" == "${DEFAULT_DERIVED_ROOT}/$(derived_key "$READ_ONLY_PROJECT")/${UDID_A}" ]] \
        || fail 'a read-only volume did not fall back to the default DerivedData location'
    grep -qF "cannot write DerivedData to ${VOLUME_DERIVED_ROOT}" "${TEST_ROOT}/derived.err" || fail 'a read-only volume gave no DerivedData warning'
done
hdiutil detach -quiet "$TEST_VOLUME" || hdiutil detach -quiet -force "$TEST_VOLUME"
TEST_VOLUME=""

# prune lists the folders of projects that are gone and deletes them only with
# --delete. It leaves alone the folder of a project that exists, a folder an
# active lease points into, a folder whose project may sit on a volume that is
# not mounted, and a folder without a marker of its own.
GONE_PROJECT="${TEST_ROOT}/worktrees/gone"
LEASED_PROJECT="${TEST_ROOT}/worktrees/leased"
GONE_DIR="${OVERRIDE_ROOT}/$(derived_key "$GONE_PROJECT")"
LEASED_DIR="${OVERRIDE_ROOT}/$(derived_key "$LEASED_PROJECT")"
UNMARKED_DIR="${OVERRIDE_ROOT}/0123456789ab"
FOREIGN_DIR="${OVERRIDE_ROOT}/aaaaaaaaaaaa"
mkdir -p "$GONE_PROJECT" "$LEASED_PROJECT" "$UNMARKED_DIR" "$FOREIGN_DIR"
jq -n --arg project "${TEST_ROOT}/worktrees/other" '{project:$project}' > "${FOREIGN_DIR}/simlease-project.json"
leased_derived_data_path "$GONE_PROJECT" "$OVERRIDE_ROOT" >/dev/null
mkdir -p "${GONE_DIR}/${UDID_A}/Build"
LEASE_A="$(SIMLEASE_WORKSPACE="$LEASED_PROJECT" SIMLEASE_DERIVED_DATA_DIR="$OVERRIDE_ROOT" "$LEASE_TOOL" acquire --device "$UDID_A" --owner derived-leased --ttl 30 --json)"
TOKEN_A="$(jq -r '.token' <<<"$LEASE_A")"
rm -rf "$GONE_PROJECT" "$LEASED_PROJECT"
PRUNE_OUTPUT="$(SIMLEASE_DERIVED_DATA_DIR="$OVERRIDE_ROOT" "$LEASE_TOOL" prune)"
[[ "$(prune_state "$PRUNE_OUTPUT" "$GONE_PROJECT")" == 'stale' ]] || fail 'prune did not list the folder of a project that is gone'
[[ -d "${GONE_DIR}/${UDID_A}/Build" ]] || fail 'prune without --delete deleted a folder'
PRUNE_OUTPUT="$("$LEASE_TOOL" prune --dir "$OVERRIDE_ROOT" --delete)"
[[ "$(prune_state "$PRUNE_OUTPUT" "$GONE_PROJECT")" == 'deleted' && ! -e "$GONE_DIR" ]] || fail 'prune --delete did not delete the folder of a project that is gone'
[[ "$(prune_state "$PRUNE_OUTPUT" "$LEASED_PROJECT")" == 'leased' && -d "$LEASED_DIR" ]] || fail 'prune --delete touched a folder under an active lease'
[[ "$(prune_state "$PRUNE_OUTPUT" "$BOOT_PROJECT")" == 'in-use' && -d "${OVERRIDE_ROOT}/$(derived_key "$BOOT_PROJECT")" ]] \
    || fail 'prune --delete touched the folder of a project that exists'
[[ "$(prune_state "$PRUNE_OUTPUT" "$VOLUME_PROJECT")" == 'unknown' && -d "${OVERRIDE_ROOT}/${VOLUME_KEY}" ]] \
    || fail 'prune --delete touched the folder of a project on a volume that is not mounted'
[[ -d "$UNMARKED_DIR" && -d "$FOREIGN_DIR" ]] || fail 'prune --delete touched a folder without a marker of its own'
"$LEASE_TOOL" release --token "$TOKEN_A" >/dev/null
TOKEN_A=""
[[ "$(prune_state "$("$LEASE_TOOL" prune --dir "$OVERRIDE_ROOT")" "$LEASED_PROJECT")" == 'stale' ]] \
    || fail 'prune did not list a released folder whose project is gone'

# Android: every lease boots its own emulator instance on a free port.
export SIMLEASE_ANDROID_TEST_STATE_DIR="${TEST_ROOT}/android"
export SIMLEASE_ANDROID_AVDS=$'avd_shared\navd_signed_in\navd_old_name'
# Keeps the Mac's real AVD folder out of the tests.
export ANDROID_AVD_HOME="${TEST_ROOT}/avd-home"
export SIMLEASE_MAX_EMULATORS=2
AND_A="$("$LEASE_TOOL" acquire --avd avd_shared --owner and-a --ttl 30 --json)"
TOKEN_A="$(jq -r '.token' <<<"$AND_A")"
[[ "$(jq -r '.platform' <<<"$AND_A")" == 'android' ]] || fail 'emulator lease does not say platform android'
[[ "$(jq -r '.serial' <<<"$AND_A")" == 'emulator-5560' ]] || fail 'first emulator did not get port 5560'
[[ "$(jq -r '.grpcPort' <<<"$AND_A")" == '8560' ]] || fail 'emulator gRPC port is not port+3000'
[[ "$(jq -r '.writable' <<<"$AND_A")" == 'false' ]] || fail 'emulator was not read-only by default'
[[ -f "${SIMLEASE_ANDROID_TEST_STATE_DIR}/emulator-5560.running" ]] || fail 'emulator was not booted'
AND_B="$("$LEASE_TOOL" acquire --android --avd avd_shared --owner and-b --ttl 30 --json)"
TOKEN_B="$(jq -r '.token' <<<"$AND_B")"
[[ "$(jq -r '.serial' <<<"$AND_B")" == 'emulator-5562' ]] || fail 'two read-only leases could not share one AVD'
if "$LEASE_TOOL" acquire --avd avd_signed_in --owner and-over --ttl 30 --json >/dev/null 2>&1; then
    fail 'an emulator lease went past SIMLEASE_MAX_EMULATORS'
fi
# shellcheck disable=SC2016 # Expanded by the leased child shell.
AND_ENV="$("$LEASE_TOOL" exec --token "$TOKEN_A" -- sh -c 'printf "%s|%s|%s|%s" "$ANDROID_SERIAL" "$ANDROID_AVD_NAME" "$ANDROID_EMULATOR_GRPC_PORT" "${SIMULATOR_UDID:-none}"')"
[[ "$AND_ENV" == 'emulator-5560|avd_shared|8560|none' ]] || fail "exec exported the wrong emulator environment: ${AND_ENV}"
[[ "$("$LEASE_TOOL" status --json | jq '[.devices[] | select(.udid | startswith("emulator-")) | select(.state == "leased")] | length')" == '2' ]] \
    || fail 'status does not list both emulator leases'
"$LEASE_TOOL" release --token "$TOKEN_B" >/dev/null
TOKEN_B=""
[[ ! -f "${SIMLEASE_ANDROID_TEST_STATE_DIR}/emulator-5562.running" ]] || fail 'release did not stop the emulator'
if "$LEASE_TOOL" acquire --avd avd_shared --writable --owner and-w --wait 1 --ttl 30 --json >/dev/null 2>&1; then
    fail 'a writable lease booted an AVD that another lease was running'
fi
"$LEASE_TOOL" release --token "$TOKEN_A" >/dev/null
TOKEN_A=""
AND_W="$("$LEASE_TOOL" acquire --avd avd_shared --writable --owner and-w --ttl 2 --json)"
[[ "$(jq -r '.writable' <<<"$AND_W")" == 'true' ]] || fail 'a writable lease was not writable'
sleep 4
[[ ! -f "${SIMLEASE_ANDROID_TEST_STATE_DIR}/emulator-5560.running" ]] || fail 'an expired emulator lease left its emulator running'
"$LEASE_TOOL" acquire --avd no_such_avd --owner and-x --json >/dev/null 2>"${TEST_ROOT}/no-avd.err" \
    && fail 'an unknown AVD was leased'
grep -q "no AVD named 'no_such_avd'" "${TEST_ROOT}/no-avd.err" || fail 'an unknown AVD failed for the wrong reason'
BOOT_STARTED="$(date +%s)"
SIMLEASE_TEST_ANDROID_BOOT_FAILS=true "$LEASE_TOOL" acquire --avd avd_shared --owner and-fail --wait 30 --json \
    >/dev/null 2>"${TEST_ROOT}/boot-fail.err" && fail 'a failed emulator boot returned a lease'
grep -q 'did not boot' "${TEST_ROOT}/boot-fail.err" || fail 'a failed emulator boot was not reported'
[[ $(( $(date +%s) - BOOT_STARTED )) -lt 20 ]] || fail 'a failed emulator boot kept retrying until --wait ran out'
# One AVD folder can have two names: a second .ini with the same path=. A
# writable lease waits for an instance started under either name.
mkdir -p "${ANDROID_AVD_HOME}/avd_shared.avd" "${ANDROID_AVD_HOME}/avd_signed_in.avd"
printf 'avd.ini.encoding=UTF-8\npath=%s\npath.rel=avd/avd_shared.avd\n' "${ANDROID_AVD_HOME}/avd_shared.avd" \
    | tee "${ANDROID_AVD_HOME}/avd_shared.ini" > "${ANDROID_AVD_HOME}/avd_old_name.ini"
printf 'avd.ini.encoding=UTF-8\npath=%s\npath.rel=avd/avd_signed_in.avd\n' "${ANDROID_AVD_HOME}/avd_signed_in.avd" \
    > "${ANDROID_AVD_HOME}/avd_signed_in.ini"
AND_A="$("$LEASE_TOOL" acquire --avd avd_old_name --owner and-old --ttl 30 --json)"
TOKEN_A="$(jq -r '.token' <<<"$AND_A")"
"$LEASE_TOOL" acquire --avd avd_shared --writable --owner and-w --wait 1 --ttl 30 --json >/dev/null 2>"${TEST_ROOT}/alias.err" \
    && fail 'a writable lease booted an AVD that was running under its other name'
grep -q 'AVD avd_shared is running elsewhere as avd_old_name' "${TEST_ROOT}/alias.err" \
    || fail 'a writable lease did not say which name the AVD runs under'
AND_B="$("$LEASE_TOOL" acquire --avd avd_signed_in --writable --owner and-other --ttl 30 --json)"
TOKEN_B="$(jq -r '.token' <<<"$AND_B")"
[[ "$(jq -r '.writable' <<<"$AND_B")" == 'true' ]] || fail 'a writable lease waited for an AVD in another folder'
"$LEASE_TOOL" release --token "$TOKEN_B" >/dev/null
TOKEN_B=""
"$LEASE_TOOL" release --token "$TOKEN_A" >/dev/null
AND_A="$("$LEASE_TOOL" acquire --avd avd_shared --owner and-new --ttl 30 --json)"
TOKEN_A="$(jq -r '.token' <<<"$AND_A")"
if "$LEASE_TOOL" acquire --avd avd_old_name --writable --owner and-w --wait 1 --ttl 30 --json >/dev/null 2>&1; then
    fail 'a writable lease under the old name booted an AVD that was running under the new name'
fi
"$LEASE_TOOL" release --token "$TOKEN_A" >/dev/null
AND_A="$("$LEASE_TOOL" acquire --avd avd_old_name --writable --owner and-w --ttl 30 --json)"
TOKEN_A="$(jq -r '.token' <<<"$AND_A")"
[[ "$(jq -r '.writable' <<<"$AND_A")" == 'true' ]] || fail 'a writable lease still waited after the other name stopped'
"$LEASE_TOOL" release --token "$TOKEN_A" >/dev/null
TOKEN_A=""
[[ -z "$(ls "$SIMLEASE_ANDROID_TEST_STATE_DIR")" ]] || fail 'emulators are still running after the Android tests'
unset SIMLEASE_ANDROID_TEST_STATE_DIR SIMLEASE_ANDROID_AVDS SIMLEASE_MAX_EMULATORS ANDROID_AVD_HOME

printf 'simulator lease tests passed\n'
