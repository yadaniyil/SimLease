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
unset SIMLEASE_DERIVED_DATA_DIR SIMLEASE_DERIVED_DATA_MAX_AGE SIMLEASE_DERIVED_DATA_MAX_TOTAL
unset SIMLEASE_DERIVED_DATA_KEEP_RECENT SIMLEASE_AUTO_PRUNE_INTERVAL
# acquire and release start a background prune; only the prune tests turn it on.
export SIMLEASE_AUTO_PRUNE=0
# The same goes for the test clone sweep. It never reaches the real testing set:
# only the clone tests name a fake simctl.
export SIMLEASE_CLONE_SWEEP=0
unset SIMLEASE_SIMCTL SIMLEASE_TEST_DEVICE_SET_DIR SIMLEASE_TEST_PS SIMLEASE_TEST_CLONE_MIN_AGE SIMLEASE_CLONE_SWEEP_INTERVAL
# And for wallpaper cache cleaning: only the poster tests turn it on, on fake
# device folders.
export SIMLEASE_POSTER_CLEAN=0
unset SIMLEASE_TEST_SIMULATOR_DEVICES_DIR SIMLEASE_POSTER_CACHE_MIN SIMLEASE_POSTER_SWEEP_INTERVAL
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
# What `prune` printed for the folder whose path ends in $2, as state/reason
# (deleted/old, kept/leased, would-delete/empty ...), or nothing.
prune_state() {
    SUFFIX="$2" awk -F '\t' '
        { start = length($5) - length(ENVIRON["SUFFIX"]) + 1 }
        start >= 1 && substr($5, start) == ENVIRON["SUFFIX"] { print $1 "/" $2 }' <<<"$1"
}
# A fake DerivedData device folder: $2 KB of data, every part of it last
# changed $3 hours ago.
fake_derived_data() {
    mkdir -p "$1/Build/Products"
    dd if=/dev/zero of="$1/Build/Products/App.bin" bs=1024 count="$2" 2>/dev/null
    find "$1" -exec touch -t "$(date -v-"$3"H '+%Y%m%d%H%M.%S')" {} +
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
grep -qF "in $(cd "$DEFAULT_DERIVED_ROOT" && pwd -P);" <<<"$("$LEASE_TOOL" prune --dry-run)" \
    || fail 'prune did not look at the default DerivedData folder'

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
grep -qF "in ${VOLUME_DERIVED_ROOT};" <<<"$(SIMLEASE_WORKSPACE="$VOLUME_PROJECT" "$LEASE_TOOL" prune --dry-run)" \
    || fail 'prune did not look at the DerivedData folder of the current volume'
# A lease remembers the folder, so a sweep started from any project looks there.
grep -qF "in ${VOLUME_DERIVED_ROOT};" <<<"$("$LEASE_TOOL" prune --dry-run)" \
    || fail 'prune did not look at the DerivedData folder of a volume a lease used before'
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

# prune in a folder outside the lease directory: only <key> folders whose
# marker names their project count. A folder whose project is gone goes once it
# is 2 h old. One whose project exists, or may sit on a volume that is not
# mounted, stays until it is 24 h old. A leased folder always stays.
GONE_PROJECT="${TEST_ROOT}/worktrees/gone"
LEASED_PROJECT="${TEST_ROOT}/worktrees/leased"
GONE_KEY="$(derived_key "$GONE_PROJECT")"
LEASED_KEY="$(derived_key "$LEASED_PROJECT")"
BOOT_KEY="$(derived_key "$BOOT_PROJECT")"
UNMARKED_DIR="${OVERRIDE_ROOT}/0123456789ab"
FOREIGN_DIR="${OVERRIDE_ROOT}/aaaaaaaaaaaa"
mkdir -p "$GONE_PROJECT" "$LEASED_PROJECT" "$FOREIGN_DIR"
jq -n --arg project "${TEST_ROOT}/worktrees/other" '{project:$project}' > "${FOREIGN_DIR}/simlease-project.json"
leased_derived_data_path "$GONE_PROJECT" "$OVERRIDE_ROOT" >/dev/null
fake_derived_data "${OVERRIDE_ROOT}/${GONE_KEY}/${UDID_A}" 64 3
fake_derived_data "${OVERRIDE_ROOT}/${BOOT_KEY}/${UDID_A}" 64 3
fake_derived_data "${OVERRIDE_ROOT}/${VOLUME_KEY}/${UDID_A}" 64 3
fake_derived_data "${UNMARKED_DIR}/${UDID_A}" 64 30
fake_derived_data "${FOREIGN_DIR}/${UDID_A}" 64 30
LEASE_A="$(SIMLEASE_WORKSPACE="$LEASED_PROJECT" SIMLEASE_DERIVED_DATA_DIR="$OVERRIDE_ROOT" "$LEASE_TOOL" acquire --device "$UDID_A" --owner derived-leased --ttl 30 --json)"
TOKEN_A="$(jq -r '.token' <<<"$LEASE_A")"
fake_derived_data "${OVERRIDE_ROOT}/${LEASED_KEY}/${UDID_A}" 64 48
rm -rf "$GONE_PROJECT" "$LEASED_PROJECT"
PRUNE_OUTPUT="$("$LEASE_TOOL" prune --dry-run --dir "$OVERRIDE_ROOT")"
[[ "$(prune_state "$PRUNE_OUTPUT" "/${GONE_KEY}/${UDID_A}")" == 'would-delete/project-gone' ]] \
    || fail 'prune --dry-run did not list the folder of a project that is gone'
[[ -d "${OVERRIDE_ROOT}/${GONE_KEY}/${UDID_A}/Build" ]] || fail 'prune --dry-run deleted a folder'
grep -q 'Nothing was deleted' <<<"$PRUNE_OUTPUT" || fail 'prune --dry-run did not say that nothing was deleted'
# --delete is what older versions needed; prune deletes without it now.
PRUNE_OUTPUT="$("$LEASE_TOOL" prune --dir "$OVERRIDE_ROOT" --delete)"
[[ "$(prune_state "$PRUNE_OUTPUT" "/${GONE_KEY}/${UDID_A}")" == 'deleted/project-gone' ]] \
    || fail 'prune did not delete the folder of a project that is gone'
[[ "$(prune_state "$PRUNE_OUTPUT" "/${GONE_KEY}")" == 'deleted/empty' && ! -e "${OVERRIDE_ROOT}/${GONE_KEY}" ]] \
    || fail 'prune did not remove the <key> folder it emptied'
[[ "$(prune_state "$PRUNE_OUTPUT" "/${LEASED_KEY}/${UDID_A}")" == 'kept/leased' && -d "${OVERRIDE_ROOT}/${LEASED_KEY}/${UDID_A}" ]] \
    || fail 'prune touched a folder under an active lease'
[[ "$(prune_state "$PRUNE_OUTPUT" "/${BOOT_KEY}/${UDID_A}")" == 'kept/fits' ]] || fail 'prune deleted the folder of a project that exists'
[[ "$(prune_state "$PRUNE_OUTPUT" "/${VOLUME_KEY}/${UDID_A}")" == 'kept/fits' ]] \
    || fail 'prune deleted the folder of a project on a volume that is not mounted'
[[ -d "${UNMARKED_DIR}/${UDID_A}" && -d "${FOREIGN_DIR}/${UDID_A}" ]] || fail 'prune touched a folder without a marker of its own'
[[ -z "$(prune_state "$PRUNE_OUTPUT" "/0123456789ab/${UDID_A}")" ]] || fail 'prune listed a folder without a marker'
[[ ! -e "${OVERRIDE_ROOT}/.simlease-trash" ]] || fail 'prune left its trash folder behind'
# release marks the folder as used just now, though nothing in it changed for two days.
"$LEASE_TOOL" release --token "$TOKEN_A" >/dev/null
TOKEN_A=""
[[ "$(prune_state "$("$LEASE_TOOL" prune --dir "$OVERRIDE_ROOT")" "/${LEASED_KEY}/${UDID_A}")" == 'kept/recent' ]] \
    || fail 'prune did not keep a folder whose lease was just released'

# prune in the lease directory's own DerivedData folder, where every <key>
# folder counts. Each device folder is judged by the newest change inside it.
(
    export SIMLEASE_DIR="${TEST_ROOT}/prune-leases"
    export SIMLEASE_WORKSPACE="${TEST_ROOT}/prune-workspace"
    mkdir -p "$SIMLEASE_WORKSPACE"
    PRUNE_TOKEN=''
    trap '[[ -z "$PRUNE_TOKEN" ]] || "$LEASE_TOOL" release --token "$PRUNE_TOKEN" >/dev/null 2>&1 || true' EXIT
    PRUNE_LEASE="$("$LEASE_TOOL" acquire --device "$UDID_A" --owner prune-leased --ttl 60 --json)"
    PRUNE_TOKEN="$(jq -r '.token' <<<"$PRUNE_LEASE")"
    ROOT="$(cd "${SIMLEASE_DIR}/derived-data" && pwd -P)"
    LEASED_FOLDER="$(jq -r '.derivedDataPath' <<<"$PRUNE_LEASE")"
    LEASED_KEY="$(basename "$(dirname "$LEASED_FOLDER")")"
    fake_derived_data "$LEASED_FOLDER" 1024 48
    fake_derived_data "${ROOT}/aaaaaaaaaaa1/${UDID_A}" 1024 30
    fake_derived_data "${ROOT}/aaaaaaaaaaa2/${UDID_A}" 1024 1
    # The folder itself and most of it are 30 h old; one file inside is new.
    fake_derived_data "${ROOT}/aaaaaaaaaaa3/${UDID_A}" 1024 30
    touch "${ROOT}/aaaaaaaaaaa3/${UDID_A}/Build/Products/App.bin"
    fake_derived_data "${ROOT}/bbbbbbbbbbb1/${UDID_A}" 1024 5
    fake_derived_data "${ROOT}/bbbbbbbbbbb2/${UDID_A}" 1024 4
    fake_derived_data "${ROOT}/bbbbbbbbbbb3/${UDID_A}" 1024 3
    mkdir -p "${ROOT}/ccccccccccc1" "${ROOT}/ccccccccccc2" "${ROOT}/ccccccccccc3/not-a-device"
    find "${ROOT}/ccccccccccc1" "${ROOT}/ccccccccccc3" -exec touch -t "$(date -v-30H '+%Y%m%d%H%M.%S')" {} +

    "$LEASE_TOOL" prune --older-than 1h >/dev/null 2>&1 && fail 'prune accepted --older-than below the 2 h it always keeps'
    "$LEASE_TOOL" prune --max-total lots >/dev/null 2>&1 && fail 'prune accepted a size it cannot read'
    "$LEASE_TOOL" prune --older-than 5x >/dev/null 2>&1 && fail 'prune accepted a duration it cannot read'

    # 7 MB in 7 folders. With a cap of 5500K: the 30 h old folder goes, then
    # the oldest of the rest (5 h) until 5 MB are left.
    PRUNE_OUTPUT="$("$LEASE_TOOL" prune --dry-run --max-total 5500K)"
    [[ "$(prune_state "$PRUNE_OUTPUT" "/aaaaaaaaaaa1/${UDID_A}")" == 'would-delete/old' ]] || fail 'prune --dry-run did not list a folder idle for 30 h'
    [[ "$(prune_state "$PRUNE_OUTPUT" "/bbbbbbbbbbb1/${UDID_A}")" == 'would-delete/over-cap' ]] || fail 'prune --dry-run did not list the oldest folder over the cap'
    [[ "$(prune_state "$PRUNE_OUTPUT" "/ccccccccccc1")" == 'would-delete/empty' ]] || fail 'prune --dry-run did not list an old empty <key> folder'
    [[ -d "${ROOT}/aaaaaaaaaaa1/${UDID_A}" && -d "${ROOT}/bbbbbbbbbbb1/${UDID_A}" && -d "${ROOT}/ccccccccccc1" ]] \
        || fail 'prune --dry-run deleted something'
    PRUNE_OUTPUT="$("$LEASE_TOOL" prune --dry-run --older-than 4h)"
    [[ "$(prune_state "$PRUNE_OUTPUT" "/bbbbbbbbbbb2/${UDID_A}")" == 'would-delete/old' \
        && "$(prune_state "$PRUNE_OUTPUT" "/bbbbbbbbbbb3/${UDID_A}")" == 'kept/fits' ]] || fail '--older-than 4h did not split 4 h from 3 h'

    # Two sweeps at once: the second waits for the first.
    "$LEASE_TOOL" prune --dry-run > "${TEST_ROOT}/prune-one.out" &
    PRUNE_ONE=$!
    "$LEASE_TOOL" prune --dry-run > "${TEST_ROOT}/prune-two.out" || fail 'a prune failed while another one ran'
    wait "$PRUNE_ONE" || fail 'a prune failed while another one ran'

    PRUNE_OUTPUT="$("$LEASE_TOOL" prune --max-total 5500K)"
    [[ "$(prune_state "$PRUNE_OUTPUT" "/aaaaaaaaaaa1/${UDID_A}")" == 'deleted/old' && ! -e "${ROOT}/aaaaaaaaaaa1" ]] \
        || fail 'prune did not delete a folder idle for 30 h, and its <key> folder'
    [[ "$(prune_state "$PRUNE_OUTPUT" "/bbbbbbbbbbb1/${UDID_A}")" == 'deleted/over-cap' && ! -e "${ROOT}/bbbbbbbbbbb1" ]] \
        || fail 'prune did not delete the oldest folder over the cap'
    [[ "$(prune_state "$PRUNE_OUTPUT" "/bbbbbbbbbbb2/${UDID_A}")" == 'kept/fits' && -d "${ROOT}/bbbbbbbbbbb2/${UDID_A}" ]] \
        || fail 'prune deleted more than the cap needed'
    [[ "$(prune_state "$PRUNE_OUTPUT" "/aaaaaaaaaaa2/${UDID_A}")" == 'kept/recent' ]] || fail 'prune did not keep a folder used 1 h ago'
    [[ "$(prune_state "$PRUNE_OUTPUT" "/aaaaaaaaaaa3/${UDID_A}")" == 'kept/recent' ]] \
        || fail 'prune judged a folder by its own mtime, not the newest file inside'
    [[ "$(prune_state "$PRUNE_OUTPUT" "/${LEASED_KEY}/${UDID_A}")" == 'kept/leased' && -d "$LEASED_FOLDER" ]] \
        || fail 'prune deleted a leased folder that is 48 h old'
    [[ ! -e "${ROOT}/ccccccccccc1" && -d "${ROOT}/ccccccccccc2" ]] || fail 'prune did not remove only the old empty <key> folder'
    [[ -d "${ROOT}/ccccccccccc3/not-a-device" ]] || fail 'prune touched a folder that is not a device folder'
    [[ ! -e "${ROOT}/.simlease-trash" ]] || fail 'prune left its trash folder behind'

    # status shows what the last sweep measured: 5 folders of 1 MB are left.
    STATUS="$("$LEASE_TOOL" status --json)"
    [[ "$(jq -r --arg root "$ROOT" '.derivedData.roots[] | select(.path == $root) | .folders' <<<"$STATUS")" == '5' ]] \
        || fail 'status does not show how many DerivedData folders are left'
    [[ "$(jq -r --arg root "$ROOT" '.derivedData.roots[] | select(.path == $root) | .totalKB' <<<"$STATUS")" -ge 5120 ]] \
        || fail 'status does not show the DerivedData size'
    "$LEASE_TOOL" status | grep -qF "DerivedData: 5.0M in 5 folder(s) at ${ROOT}" || fail 'status text does not show the DerivedData size'

    # A cap of 0 deletes every folder that is neither leased nor recent.
    PRUNE_OUTPUT="$("$LEASE_TOOL" prune --max-total 0)"
    [[ ! -e "${ROOT}/bbbbbbbbbbb2" && ! -e "${ROOT}/bbbbbbbbbbb3" && -d "${ROOT}/aaaaaaaaaaa2/${UDID_A}" && -d "$LEASED_FOLDER" ]] \
        || fail 'a cap of 0 did not delete exactly the folders that are neither leased nor recent'
    grep -q 'Still over the cap' <<<"$PRUNE_OUTPUT" || fail 'prune did not say it is still over the cap'

    # acquire and release start the same sweep in the background, at most once
    # every SIMLEASE_AUTO_PRUNE_INTERVAL. It outlives the process group of the
    # command that started it, as when an agent's tool call ends.
    fake_derived_data "${ROOT}/ddddddddddd1/${UDID_A}" 64 30
    python3 - "$LEASE_TOOL" "$PRUNE_TOKEN" <<'PY'
import os
import signal
import subprocess
import sys

lease_tool, token = sys.argv[1:]
environment = os.environ | {"SIMLEASE_AUTO_PRUNE": "1", "SIMLEASE_AUTO_PRUNE_INTERVAL": "0"}
release = subprocess.Popen(
    [lease_tool, "release", "--token", token],
    stdout=subprocess.DEVNULL,
    stderr=subprocess.PIPE,
    text=True,
    env=environment,
    start_new_session=True,
)
_, stderr = release.communicate(timeout=30)
if release.returncode != 0:
    raise SystemExit(f"release failed: {stderr}")
try:
    os.killpg(release.pid, signal.SIGKILL)
except ProcessLookupError:
    pass
PY
    PRUNE_TOKEN=''
    for _ in $(seq 1 60); do
        [[ -e "${ROOT}/ddddddddddd1" ]] || break
        sleep 0.5
    done
    [[ ! -e "${ROOT}/ddddddddddd1" ]] || fail 'release did not prune an old folder in the background'
    grep -qE "^deleted.old.+/ddddddddddd1/${UDID_A}$" "${SIMLEASE_DIR}/derived-data-prune.log" \
        || fail 'the background prune did not log what it deleted'
    fake_derived_data "${ROOT}/ddddddddddd2/${UDID_A}" 64 30
    SWEEPS="$(grep -c 'auto-prune' "${SIMLEASE_DIR}/derived-data-prune.log")"
    PRUNE_TOKEN="$(SIMLEASE_AUTO_PRUNE=1 SIMLEASE_AUTO_PRUNE_INTERVAL=1h "$LEASE_TOOL" acquire --device "$UDID_A" --owner throttled --ttl 30 --json | jq -r '.token')"
    SIMLEASE_AUTO_PRUNE=1 SIMLEASE_AUTO_PRUNE_INTERVAL=1h "$LEASE_TOOL" release --token "$PRUNE_TOKEN" >/dev/null
    PRUNE_TOKEN="$(SIMLEASE_AUTO_PRUNE=0 SIMLEASE_AUTO_PRUNE_INTERVAL=0 "$LEASE_TOOL" acquire --device "$UDID_A" --owner auto-off --ttl 30 --json | jq -r '.token')"
    "$LEASE_TOOL" release --token "$PRUNE_TOKEN" >/dev/null
    PRUNE_TOKEN=''
    sleep 3
    [[ -d "${ROOT}/ddddddddddd2/${UDID_A}" ]] || fail 'a background prune ran within its interval, or with SIMLEASE_AUTO_PRUNE=0'
    [[ "$(grep -c 'auto-prune' "${SIMLEASE_DIR}/derived-data-prune.log")" == "$SWEEPS" ]] || fail 'a background prune ran when it should not'
    # A setting it cannot read skips the sweep and never fails the lease.
    PRUNE_TOKEN="$(SIMLEASE_AUTO_PRUNE=1 SIMLEASE_AUTO_PRUNE_INTERVAL=0 SIMLEASE_DERIVED_DATA_MAX_TOTAL=lots \
        "$LEASE_TOOL" acquire --device "$UDID_A" --owner bad-setting --ttl 30 --json | jq -r '.token')"
    [[ -n "$PRUNE_TOKEN" && "$PRUNE_TOKEN" != 'null' ]] || fail 'a bad prune setting failed the acquire'
    "$LEASE_TOOL" release --token "$PRUNE_TOKEN" >/dev/null
    PRUNE_TOKEN=''
    for _ in $(seq 1 20); do
        ! grep -q 'auto-prune skipped' "${SIMLEASE_DIR}/derived-data-prune.log" || break
        sleep 0.5
    done
    grep -q 'auto-prune skipped' "${SIMLEASE_DIR}/derived-data-prune.log" || fail 'a bad prune setting was not logged'
    [[ -d "${ROOT}/ddddddddddd2/${UDID_A}" ]] || fail 'a sweep with a bad setting deleted something'
)

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

# sweep-clones: Xcode's testing device set, faked as folders. The fake simctl
# lists every folder that holds a device.plist, deletes one UDID at a time, and
# logs every call.
(
    CLONE_ROOT="${TEST_ROOT}/clones"
    export SIMLEASE_DIR="${CLONE_ROOT}/leases"
    export SIMLEASE_TEST_DEVICE_SET_DIR="${CLONE_ROOT}/XCTestDevices"
    export SIMLEASE_SIMCTL="${CLONE_ROOT}/simctl"
    export SIMCTL_CALLS="${CLONE_ROOT}/simctl-calls"
    # An xcodebuild that started 1 h ago still runs (from a path with a space).
    export SIMLEASE_TEST_PS=$'    01:00:00 /Applications/Xcode 27.app/Contents/Developer/usr/bin/xcodebuild\n 2-03:00:00 /usr/libexec/logd'
    mkdir -p "$SIMLEASE_TEST_DEVICE_SET_DIR"
    : > "$SIMCTL_CALLS"
    cat > "$SIMLEASE_SIMCTL" <<'SH'
#!/bin/bash
set -euo pipefail
printf '%s\n' "$*" >> "$SIMCTL_CALLS"
[[ "${1:-}" == "--set" && "${2:-}" == "testing" ]] || exit 64
shift 2
set_dir="$SIMLEASE_TEST_DEVICE_SET_DIR"
case "${1:-}" in
    list)
        [[ "$*" == "list devices -j" ]] || exit 64
        printf "Using Parallel Testing Device Clones Device Set: '%s'\n" "$set_dir" >&2
        for plist in "$set_dir"/*/device.plist; do
            [[ -f "$plist" ]] || continue
            folder="${plist%/device.plist}"
            case "$(plutil -extract state raw "$plist")" in
                1) state=Shutdown ;; 2) state=Booting ;; 3) state=Booted ;; 4) state='Shutting Down' ;; *) state=Creating ;;
            esac
            jq -n --arg udid "${folder##*/}" --arg state "$state" --arg name "$(plutil -extract name raw "$plist")" \
                --arg dataPath "${folder}/data" '{udid: $udid, state: $state, name: $name, dataPath: $dataPath, isAvailable: true}'
        done | jq -s '{devices: {"com.apple.CoreSimulator.SimRuntime.iOS-27-0": .}}'
        ;;
    delete)
        [[ $# -eq 2 && "$2" =~ ^[0-9A-F]{8}-[0-9A-F]{4}-[0-9A-F]{4}-[0-9A-F]{4}-[0-9A-F]{12}$ ]] || exit 64
        rm -rf "${set_dir:?}/$2"
        ;;
    *) exit 64 ;;
esac
SH
    chmod +x "$SIMLEASE_SIMCTL"
    # A device in the set: UDID, name, CoreSimulator state (1 shut down, 2
    # booting, 3 booted), and how many minutes ago it was made and last changed.
    fake_set_device() {
        local folder="${SIMLEASE_TEST_DEVICE_SET_DIR}/$1"
        mkdir -p "${folder}/data/Library"
        printf 'x' > "${folder}/data/Library/file"
        printf '<?xml version="1.0" encoding="UTF-8"?>\n<plist version="1.0"><dict><key>UDID</key><string>%s</string><key>name</key><string>%s</string><key>state</key><integer>%s</integer></dict></plist>\n' \
            "$1" "$2" "$3" > "${folder}/device.plist"
        find "$folder" -exec touch -t "$(date -v-"$4"M '+%Y%m%d%H%M.%S')" {} +
    }
    # A UDID folder with no device.plist: empty folders only, or one file too.
    fake_set_folder() {
        local folder="${SIMLEASE_TEST_DEVICE_SET_DIR}/$1"
        mkdir -p "${folder}/data/tmp"
        [[ "${3:-}" != "file" ]] || printf 'x' > "${folder}/data/file"
        find "$folder" -exec touch -t "$(date -v-"$2"M '+%Y%m%d%H%M.%S')" {} +
    }
    # What sweep-clones printed for a UDID, as action/reason, or nothing.
    clone_state() {
        awk -F '\t' -v udid="$2" '$4 == udid { print $1 "/" $2 }' <<<"$1"
    }
    OLD='A0000000-0000-0000-0000-000000000001'
    OLDER='A0000000-0000-0000-0000-000000000002'
    BOOTED='A0000000-0000-0000-0000-000000000003'
    BOOTING='A0000000-0000-0000-0000-000000000004'
    RECENT='A0000000-0000-0000-0000-000000000005'
    RUNNING='A0000000-0000-0000-0000-000000000006'
    PLAIN='A0000000-0000-0000-0000-000000000007'
    EMPTY_OLD='A0000000-0000-0000-0000-000000000008'
    EMPTY_NEW='A0000000-0000-0000-0000-000000000009'
    WITH_FILE='A0000000-0000-0000-0000-00000000000A'
    fake_set_device "$OLD" 'Clone 2 of iPhone 1' 1 180
    fake_set_device "$OLDER" 'Clone 12 of Family Cards shots iPhone' 1 2880
    fake_set_device "$BOOTED" 'Clone 1 of iPhone 2' 3 180
    fake_set_device "$BOOTING" 'Clone 1 of iPhone 3' 2 180
    fake_set_device "$RECENT" 'Clone 2 of iPhone 3' 1 20
    # Made 45 min ago, after the running xcodebuild started: it may be that run's.
    fake_set_device "$RUNNING" 'Clone 3 of iPhone 1' 1 45
    fake_set_device "$PLAIN" 'iPhone 17 Pro' 1 2880
    fake_set_folder "$EMPTY_OLD" 2880
    fake_set_folder "$EMPTY_NEW" 120
    fake_set_folder "$WITH_FILE" 2880 file
    mkdir -p "${SIMLEASE_TEST_DEVICE_SET_DIR}/not-a-udid"

    "$LEASE_TOOL" sweep-clones --older-than 5m >/dev/null 2>&1 && fail 'sweep-clones accepted --older-than below 10m'
    "$LEASE_TOOL" sweep-clones --older-than soon >/dev/null 2>&1 && fail 'sweep-clones accepted a duration it cannot read'
    "$LEASE_TOOL" sweep-clones --all >/dev/null 2>&1 && fail 'sweep-clones accepted an unknown option'

    CLONE_OUTPUT="$("$LEASE_TOOL" sweep-clones --dry-run)"
    [[ "$(clone_state "$CLONE_OUTPUT" "$OLD")" == 'would-delete/old' ]] || fail 'sweep-clones --dry-run did not list a clone shut down 3 h ago'
    [[ "$(clone_state "$CLONE_OUTPUT" "$OLDER")" == 'would-delete/old' ]] || fail 'sweep-clones --dry-run did not list a clone shut down 2 days ago'
    [[ "$(clone_state "$CLONE_OUTPUT" "$EMPTY_OLD")" == 'would-delete/empty' ]] || fail 'sweep-clones --dry-run did not list an old empty folder'
    grep -q 'Nothing was deleted' <<<"$CLONE_OUTPUT" || fail 'sweep-clones --dry-run did not say that nothing was deleted'
    ! grep -q ' delete ' "$SIMCTL_CALLS" || fail 'sweep-clones --dry-run called simctl delete'
    [[ -d "${SIMLEASE_TEST_DEVICE_SET_DIR}/${OLD}" && -d "${SIMLEASE_TEST_DEVICE_SET_DIR}/${EMPTY_OLD}" ]] || fail 'sweep-clones --dry-run deleted something'

    CLONE_OUTPUT="$("$LEASE_TOOL" sweep-clones)"
    [[ "$(clone_state "$CLONE_OUTPUT" "$OLD")" == 'deleted/old' && ! -e "${SIMLEASE_TEST_DEVICE_SET_DIR}/${OLD}" ]] \
        || fail 'sweep-clones did not delete a clone shut down 3 h ago'
    [[ "$(clone_state "$CLONE_OUTPUT" "$OLDER")" == 'deleted/old' && ! -e "${SIMLEASE_TEST_DEVICE_SET_DIR}/${OLDER}" ]] \
        || fail 'sweep-clones did not delete a clone shut down 2 days ago'
    [[ "$(clone_state "$CLONE_OUTPUT" "$BOOTED")" == 'kept/booted' && -d "${SIMLEASE_TEST_DEVICE_SET_DIR}/${BOOTED}" ]] \
        || fail 'sweep-clones touched a booted clone'
    [[ "$(clone_state "$CLONE_OUTPUT" "$BOOTING")" == 'kept/booting' && -d "${SIMLEASE_TEST_DEVICE_SET_DIR}/${BOOTING}" ]] \
        || fail 'sweep-clones touched a booting clone'
    [[ "$(clone_state "$CLONE_OUTPUT" "$RECENT")" == 'kept/recent' && -d "${SIMLEASE_TEST_DEVICE_SET_DIR}/${RECENT}" ]] \
        || fail 'sweep-clones touched a clone that changed 20 min ago'
    [[ "$(clone_state "$CLONE_OUTPUT" "$RUNNING")" == 'kept/xcodebuild-running' && -d "${SIMLEASE_TEST_DEVICE_SET_DIR}/${RUNNING}" ]] \
        || fail 'sweep-clones touched a clone made after a running xcodebuild started'
    [[ -z "$(clone_state "$CLONE_OUTPUT" "$PLAIN")" && -d "${SIMLEASE_TEST_DEVICE_SET_DIR}/${PLAIN}" ]] \
        || fail 'sweep-clones touched a device that is not a clone'
    [[ "$(clone_state "$CLONE_OUTPUT" "$EMPTY_OLD")" == 'deleted/empty' && ! -e "${SIMLEASE_TEST_DEVICE_SET_DIR}/${EMPTY_OLD}" ]] \
        || fail 'sweep-clones did not remove an empty folder 2 days old'
    [[ "$(clone_state "$CLONE_OUTPUT" "$EMPTY_NEW")" == 'kept/recent' && -d "${SIMLEASE_TEST_DEVICE_SET_DIR}/${EMPTY_NEW}/data/tmp" ]] \
        || fail 'sweep-clones removed an empty folder 2 h old'
    [[ -z "$(clone_state "$CLONE_OUTPUT" "$WITH_FILE")" && -f "${SIMLEASE_TEST_DEVICE_SET_DIR}/${WITH_FILE}/data/file" ]] \
        || fail 'sweep-clones touched a folder with a file in it'
    [[ -d "${SIMLEASE_TEST_DEVICE_SET_DIR}/not-a-udid" ]] || fail 'sweep-clones touched a folder that is not a UDID'
    # Every delete names one UDID; nothing ever deletes "all".
    [[ "$(grep -c ' delete ' "$SIMCTL_CALLS")" -eq 2 ]] || fail 'sweep-clones did not call simctl delete once per old clone'
    grep -qx -- "--set testing delete ${OLD}" "$SIMCTL_CALLS" || fail 'sweep-clones did not delete through simctl --set testing delete <UDID>'
    grep -qx -- "--set testing delete ${OLDER}" "$SIMCTL_CALLS" || fail 'sweep-clones did not delete through simctl --set testing delete <UDID>'
    ! grep -q 'all' "$SIMCTL_CALLS" || fail 'sweep-clones called simctl with all'

    # Once that xcodebuild has ended, its clone goes.
    CLONE_OUTPUT="$(SIMLEASE_TEST_PS='' "$LEASE_TOOL" sweep-clones)"
    [[ "$(clone_state "$CLONE_OUTPUT" "$RUNNING")" == 'deleted/old' ]] || fail 'sweep-clones kept a clone after its xcodebuild ended'

    # The tests' fake Simulators never reach the real testing set.
    [[ "$(SIMLEASE_SIMCTL='' "$LEASE_TOOL" sweep-clones)" == Skipped:* ]] || fail 'sweep-clones ran with fake Simulators and no fake simctl'

    # acquire and release sweep in the background, at most once every
    # SIMLEASE_CLONE_SWEEP_INTERVAL, and log what they delete.
    SWEPT='A0000000-0000-0000-0000-00000000000B'
    fake_set_device "$SWEPT" 'Clone 2 of iPhone 2' 1 180
    CLONE_LEASE="$("$LEASE_TOOL" acquire --owner clone-sweep --ttl 30 --json)"
    SIMLEASE_CLONE_SWEEP=1 SIMLEASE_CLONE_SWEEP_INTERVAL=0 "$LEASE_TOOL" release --token "$(jq -r '.token' <<<"$CLONE_LEASE")" >/dev/null
    for _ in $(seq 1 100); do
        grep -q "deleted	old	.*	${SWEPT}	Clone 2 of iPhone 2" "${SIMLEASE_DIR}/test-clone-sweep.log" 2>/dev/null && break
        sleep 0.1
    done
    [[ ! -e "${SIMLEASE_TEST_DEVICE_SET_DIR}/${SWEPT}" ]] || fail 'release did not sweep an old clone in the background'
    grep -q "deleted	old	.*	${SWEPT}	Clone 2 of iPhone 2" "${SIMLEASE_DIR}/test-clone-sweep.log" \
        || fail 'the background clone sweep did not log what it deleted'
    ! grep -q -e 'kept' -e "$BOOTED" "${SIMLEASE_DIR}/test-clone-sweep.log" || fail 'the background clone sweep logged a clone it kept'
    # Wait for that sweep to finish before the next clone appears.
    lockf -t 10 "${SIMLEASE_DIR}/locks/test-clone-sweep.lock" true || fail 'the background clone sweep did not finish'
    fake_set_device "$SWEPT" 'Clone 2 of iPhone 2' 1 180
    CLONE_LEASE="$(SIMLEASE_CLONE_SWEEP=1 SIMLEASE_CLONE_SWEEP_INTERVAL=1h "$LEASE_TOOL" acquire --owner clone-sweep --ttl 30 --json)"
    SIMLEASE_CLONE_SWEEP=1 SIMLEASE_CLONE_SWEEP_INTERVAL=1h "$LEASE_TOOL" release --token "$(jq -r '.token' <<<"$CLONE_LEASE")" >/dev/null
    sleep 2
    [[ -d "${SIMLEASE_TEST_DEVICE_SET_DIR}/${SWEPT}" ]] || fail 'a background clone sweep ran again within SIMLEASE_CLONE_SWEEP_INTERVAL'
)

# clean-posters: iOS wallpaper preview caches in fake Simulator folders. Each
# fake device.plist gives a state (1 shut down, 3 booted); a lease's boot is a
# marker file, as in the scaling tests.
(
    POSTER_ROOT="${TEST_ROOT}/posters"
    export SIMLEASE_DIR="${POSTER_ROOT}/leases"
    export SIMLEASE_TEST_SIMULATOR_DEVICES_DIR="${POSTER_ROOT}/Devices"
    export SIMLEASE_TEST_DEVICE_STATE_DIR="${POSTER_ROOT}/device-state"
    export SIMLEASE_TEST_TOTAL_MEMORY_MB=32768
    export SIMLEASE_TEST_FREE_MEMORY_PERCENT=50
    export SIMLEASE_MAX_BOOTED_SIMULATORS=4
    export SIMLEASE_POSTER_CACHE_MIN=1M
    # Only the background test below lets acquire and release start a sweep.
    export SIMLEASE_POSTER_SWEEP_INTERVAL=off
    POSTER_LOG="${SIMLEASE_DIR}/poster-cache.log"
    BIG='B0000000-0000-0000-0000-000000000001'
    SMALL='B0000000-0000-0000-0000-000000000002'
    BOOTED='B0000000-0000-0000-0000-000000000003'
    PINNED='B0000000-0000-0000-0000-000000000004'
    NONE='B0000000-0000-0000-0000-000000000005'
    LEASED='B0000000-0000-0000-0000-000000000006'
    IDLE='B0000000-0000-0000-0000-000000000007'
    export SIMLEASE_SHUTDOWN_DEVICES="${LEASED}"$'\tiPhone Poster Lease'
    mkdir -p "$SIMLEASE_TEST_DEVICE_STATE_DIR" "$SIMLEASE_CONFIG_DIR"
    printf '%s  # signed in\n' "$PINNED" > "${SIMLEASE_CONFIG_DIR}/pinned"
    POSTER_TOKEN=''
    trap '[[ -z "$POSTER_TOKEN" ]] || "$LEASE_TOOL" release --token "$POSTER_TOKEN" >/dev/null 2>&1 || true; rm -f "${SIMLEASE_CONFIG_DIR}/pinned"' EXIT

    store_of() { printf '%s/%s/data/Library/Application Support/PRBPosterExtensionDataStore/61' "$SIMLEASE_TEST_SIMULATOR_DEVICES_DIR" "$1"; }
    config_of() { printf '%s/Extensions/com.apple.MercuryPoster/configurations/C0000000-0000-0000-0000-000000000001' "$(store_of "$1")"; }
    gallery_cache_of() { printf '%s/Extensions/com.apple.EmojiPoster.EmojiPosterExtension/descriptors/D0000000-0000-0000-0000-000000000001/versions/1/scratch/SnapshotCache.cachedb' "$(store_of "$1")"; }
    chosen_cache_of() { printf '%s/versions/0/scratch/SnapshotCache.cachedb' "$(config_of "$1")"; }
    # A Simulator folder: UDID, name, state, then KiB of cache in each of its two
    # caches (a gallery preview and the chosen wallpaper's), or "none" for no
    # wallpaper store at all.
    fake_poster_device() {
        local device="${SIMLEASE_TEST_SIMULATOR_DEVICES_DIR}/$1"
        local store
        mkdir -p "$device"
        printf '<?xml version="1.0" encoding="UTF-8"?>\n<plist version="1.0"><dict><key>UDID</key><string>%s</string><key>name</key><string>%s</string><key>state</key><integer>%s</integer></dict></plist>\n' \
            "$1" "$2" "$3" > "${device}/device.plist"
        [[ "$4" != "none" ]] || return 0
        store="$(store_of "$1")"
        mkdir -p "${store}/GalleryCache/PRPosterRoleLockScreen" "$(config_of "$1")/versions/0"
        printf 'db' > "${store}/PBFPosterExtensionDataStoreSQLiteDatabase.sqlite3"
        printf 'layout' > "${store}/GalleryCache/PRPosterRoleLockScreen/1792880002.788442.plist"
        # The chosen wallpaper: its settings and lock and home screen pictures.
        printf 'settings' > "$(config_of "$1")/providerInfo.plist"
        printf 'picture' > "$(config_of "$1")/versions/0/RuntimeSnapshot-0073ad-home.atx"
        # An empty cache, and a cache folder where iOS keeps none: both stay.
        mkdir -p "${store}/Extensions/com.apple.ClockPoster.ClockPosterExtension/configurations/C0000000-0000-0000-0000-000000000002/versions/3/scratch/SnapshotCache.cachedb"
        mkdir -p "${store}/Extensions/com.apple.Other/SnapshotCache.cachedb"
        printf 'x' > "${store}/Extensions/com.apple.Other/SnapshotCache.cachedb/keep"
        fake_poster_cache "$1" "$4"
    }
    # Fills both caches with KiB each, and writes the two index files.
    fake_poster_cache() {
        local store
        local cache
        store="$(store_of "$1")"
        for cache in "$(gallery_cache_of "$1")" "$(chosen_cache_of "$1")"; do
            mkdir -p "${cache}/PosterSnapshotCache.bundle/SnapshotBundles/E0000000-0000-0000-0000-000000000001"
            printf 'db' > "${cache}/PosterSnapshotCache.bundle/cache.db"
            dd if=/dev/urandom of="${cache}/PosterSnapshotCache.bundle/SnapshotBundles/E0000000-0000-0000-0000-000000000001/Snapshot.pks" \
                bs=1024 count="$2" 2>/dev/null
        done
        printf '{"experience":"gallery"}' > "${store}/PRPosterRoleLockScreen-gallery-index.json"
        printf '{"experience":"switcher"}' > "${store}/PRPosterRoleLockScreen-switcher-index.json"
    }
    has_caches() { [[ -e "$(gallery_cache_of "$1")" || -e "$(chosen_cache_of "$1")" ]]; }
    has_all_caches() {
        [[ -d "$(gallery_cache_of "$1")" && -d "$(chosen_cache_of "$1")" \
            && -f "$(store_of "$1")/PRPosterRoleLockScreen-gallery-index.json" \
            && -f "$(store_of "$1")/PRPosterRoleLockScreen-switcher-index.json" ]]
    }
    # Everything that is not a cache is still there.
    kept_the_rest() {
        local store
        store="$(store_of "$1")"
        [[ -f "$(config_of "$1")/providerInfo.plist" && -f "$(config_of "$1")/versions/0/RuntimeSnapshot-0073ad-home.atx" \
            && -f "${store}/PBFPosterExtensionDataStoreSQLiteDatabase.sqlite3" \
            && -f "${store}/GalleryCache/PRPosterRoleLockScreen/1792880002.788442.plist" \
            && -d "$(dirname "$(gallery_cache_of "$1")")" && -d "$(dirname "$(chosen_cache_of "$1")")" \
            && -d "${store}/Extensions/com.apple.ClockPoster.ClockPosterExtension/configurations/C0000000-0000-0000-0000-000000000002/versions/3/scratch/SnapshotCache.cachedb" \
            && -f "${store}/Extensions/com.apple.Other/SnapshotCache.cachedb/keep" \
            && ! -e "${SIMLEASE_TEST_SIMULATOR_DEVICES_DIR}/$1/data/Library/Application Support/.simlease-poster-trash" ]]
    }
    # What clean-posters printed for a UDID, as action/reason, or nothing.
    poster_state() {
        awk -F '\t' -v udid="$2" '$4 == udid { print $1 "/" $2 }' <<<"$1"
    }
    # Waits for the guard of a lease that ended: it holds the Simulator's lock
    # while it cleans.
    wait_for_guard() {
        lockf -k -t 15 "${SIMLEASE_DIR}/locks/$1.lock" true || fail "the lease guard of $1 did not finish"
    }

    fake_poster_device "$BIG" 'iPhone Big' 1 1024
    fake_poster_device "$SMALL" 'iPhone Small' 1 4
    fake_poster_device "$BOOTED" 'iPhone Booted' 3 1024
    fake_poster_device "$PINNED" 'iPhone Pinned' 1 1024
    fake_poster_device "$NONE" 'iPhone No Store' 1 none
    fake_poster_device "$LEASED" 'iPhone Poster Lease' 1 1024
    fake_poster_device "$IDLE" 'iPhone Idle' 1 1024

    "$LEASE_TOOL" clean-posters --min-size soon >/dev/null 2>&1 && fail 'clean-posters accepted a size it cannot read'
    "$LEASE_TOOL" clean-posters --all >/dev/null 2>&1 && fail 'clean-posters accepted an unknown option'
    "$LEASE_TOOL" clean-posters --token not-a-lease >/dev/null 2>&1 && fail 'clean-posters accepted a token with no lease'

    POSTER_OUTPUT="$("$LEASE_TOOL" clean-posters --min-size 1M --dry-run)"
    [[ "$(poster_state "$POSTER_OUTPUT" "$BIG")" == 'would-clean/wallpaper-cache' ]] || fail 'clean-posters --dry-run did not list a shut-down Simulator with 2 MB of cache'
    [[ "$(poster_state "$POSTER_OUTPUT" "$SMALL")" == 'kept/small' ]] || fail 'clean-posters --dry-run did not keep a cache below --min-size'
    [[ "$(poster_state "$POSTER_OUTPUT" "$BOOTED")" == 'kept/booted' ]] || fail 'clean-posters --dry-run did not keep a booted Simulator'
    [[ "$(poster_state "$POSTER_OUTPUT" "$PINNED")" == 'kept/pinned' ]] || fail 'clean-posters --dry-run did not keep a pinned Simulator'
    [[ -z "$(poster_state "$POSTER_OUTPUT" "$NONE")" ]] || fail 'clean-posters --dry-run listed a Simulator with no wallpaper store'
    grep -q $'\t2 caches, 2 index files$' <<<"$POSTER_OUTPUT" || fail 'clean-posters --dry-run did not count the caches and index files'
    grep -q 'Nothing was deleted' <<<"$POSTER_OUTPUT" || fail 'clean-posters --dry-run did not say that nothing was deleted'
    has_all_caches "$BIG" || fail 'clean-posters --dry-run deleted something'
    [[ ! -e "$POSTER_LOG" ]] || fail 'clean-posters --dry-run wrote to the log'

    # A Simulator a lease holds is left alone by the sweep.
    POSTER_LEASE="$(SIMLEASE_POSTER_CLEAN=0 "$LEASE_TOOL" acquire --owner posters --device "$LEASED" --boot-if-needed --ttl 60 --json)"
    POSTER_TOKEN="$(jq -r '.token' <<<"$POSTER_LEASE")"
    rm -f "${SIMLEASE_TEST_DEVICE_STATE_DIR}/${LEASED}.booted"
    POSTER_OUTPUT="$("$LEASE_TOOL" clean-posters --min-size 1M)"
    [[ "$(poster_state "$POSTER_OUTPUT" "$BIG")" == 'cleaned/wallpaper-cache' ]] || fail 'clean-posters did not clean a shut-down Simulator'
    ! has_caches "$BIG" || fail 'clean-posters left a cache behind'
    [[ ! -e "$(store_of "$BIG")/PRPosterRoleLockScreen-gallery-index.json" && ! -e "$(store_of "$BIG")/PRPosterRoleLockScreen-switcher-index.json" ]] \
        || fail 'clean-posters left an index file that points into the deleted caches'
    kept_the_rest "$BIG" || fail 'clean-posters deleted something that is not a wallpaper cache'
    has_all_caches "$SMALL" || fail 'clean-posters cleaned a cache below --min-size'
    has_all_caches "$BOOTED" || fail 'clean-posters touched a booted Simulator'
    has_all_caches "$PINNED" || fail 'clean-posters touched a pinned Simulator'
    [[ "$(poster_state "$POSTER_OUTPUT" "$LEASED")" == 'kept/leased' ]] || fail 'clean-posters did not keep a Simulator another lease holds'
    has_all_caches "$LEASED" || fail 'clean-posters touched a Simulator another lease holds'
    grep -q $'^cleaned\twallpaper-cache\t.*\t'"${BIG}"$'\tiPhone Big\t' "$POSTER_LOG" || fail 'clean-posters did not log what it cleaned'
    ! grep -q -e "$SMALL" -e "$BOOTED" "$POSTER_LOG" || fail 'clean-posters logged a Simulator it kept'
    # Without --min-size it cleans any cache.
    POSTER_OUTPUT="$("$LEASE_TOOL" clean-posters)"
    [[ "$(poster_state "$POSTER_OUTPUT" "$SMALL")" == 'cleaned/wallpaper-cache' ]] || fail 'clean-posters without --min-size kept a small cache'
    ! has_caches "$SMALL" || fail 'clean-posters without --min-size left a small cache behind'
    kept_the_rest "$SMALL" || fail 'clean-posters deleted something that is not a wallpaper cache'

    # With a token: only the leased Simulator, and only once it is shut down.
    POSTER_OUTPUT="$("$LEASE_TOOL" clean-posters --token "$POSTER_TOKEN" --dry-run)"
    [[ "$(poster_state "$POSTER_OUTPUT" "$LEASED")" == 'would-clean/wallpaper-cache' ]] || fail 'clean-posters --token --dry-run did not list the leased Simulator'
    has_all_caches "$LEASED" || fail 'clean-posters --token --dry-run deleted something'
    : > "${SIMLEASE_TEST_DEVICE_STATE_DIR}/${LEASED}.booted"
    "$LEASE_TOOL" clean-posters --token "$POSTER_TOKEN" >/dev/null 2>&1 && fail 'clean-posters cleaned a booted leased Simulator'
    has_all_caches "$LEASED" || fail 'clean-posters touched a booted leased Simulator'
    rm -f "${SIMLEASE_TEST_DEVICE_STATE_DIR}/${LEASED}.booted"
    POSTER_OUTPUT="$("$LEASE_TOOL" clean-posters --token "$POSTER_TOKEN")"
    [[ "$(poster_state "$POSTER_OUTPUT" "$LEASED")" == 'cleaned/wallpaper-cache' ]] || fail 'clean-posters --token did not clean the shut-down leased Simulator'
    ! has_caches "$LEASED" || fail 'clean-posters --token left a cache behind'
    kept_the_rest "$LEASED" || fail 'clean-posters --token deleted something that is not a wallpaper cache'
    [[ "$("$LEASE_TOOL" clean-posters --token "$POSTER_TOKEN")" == 'No wallpaper caches on iPhone Poster Lease.' ]] \
        || fail 'clean-posters --token did not say there was nothing to clean'
    "$LEASE_TOOL" release --token "$POSTER_TOKEN" >/dev/null
    POSTER_TOKEN=''
    wait_for_guard "$LEASED"

    # The guard keeps the SIMLEASE_POSTER_CLEAN its acquire had. Off: it cleans
    # neither before the boot nor after the shutdown.
    fake_poster_cache "$LEASED" 1024
    POSTER_LEASE="$(SIMLEASE_POSTER_CLEAN=0 "$LEASE_TOOL" acquire --owner posters --device "$LEASED" --boot-if-needed --ttl 60 --json)"
    POSTER_TOKEN="$(jq -r '.token' <<<"$POSTER_LEASE")"
    has_all_caches "$LEASED" || fail 'acquire cleaned caches with SIMLEASE_POSTER_CLEAN=0'
    "$LEASE_TOOL" release --token "$POSTER_TOKEN" >/dev/null
    POSTER_TOKEN=''
    wait_for_guard "$LEASED"
    has_all_caches "$LEASED" || fail 'release cleaned caches with SIMLEASE_POSTER_CLEAN=0'

    # Acquire: the guard cleans a shut-down Simulator before it boots it.
    POSTER_LEASE="$(SIMLEASE_POSTER_CLEAN=1 "$LEASE_TOOL" acquire --owner posters --device "$LEASED" --boot-if-needed --ttl 60 --json)"
    POSTER_TOKEN="$(jq -r '.token' <<<"$POSTER_LEASE")"
    [[ "$(jq -r '.bootedBySimLease' <<<"$POSTER_LEASE")" == 'true' && -f "${SIMLEASE_TEST_DEVICE_STATE_DIR}/${LEASED}.booted" ]] \
        || fail 'the poster lease did not boot its Simulator'
    ! has_caches "$LEASED" || fail 'acquire did not clean the Simulator before it booted it'
    kept_the_rest "$LEASED" || fail 'acquire deleted something that is not a wallpaper cache'
    grep -q 'boot$' "$POSTER_LOG" || fail 'the boot clean did not log under "boot"'
    # Release: the guard cleans what this boot drew, once it has shut the Simulator down.
    fake_poster_cache "$LEASED" 1024
    "$LEASE_TOOL" release --token "$POSTER_TOKEN" >/dev/null
    POSTER_TOKEN=''
    wait_for_guard "$LEASED"
    ! has_caches "$LEASED" || fail 'release did not clean the Simulator it shut down'
    kept_the_rest "$LEASED" || fail 'release deleted something that is not a wallpaper cache'
    grep -q 'release$' "$POSTER_LOG" || fail 'the release clean did not log under "release"'

    # Release leaves a cache below SIMLEASE_POSTER_CACHE_MIN.
    POSTER_LEASE="$(SIMLEASE_POSTER_CLEAN=1 "$LEASE_TOOL" acquire --owner posters --device "$LEASED" --boot-if-needed --ttl 60 --json)"
    POSTER_TOKEN="$(jq -r '.token' <<<"$POSTER_LEASE")"
    fake_poster_cache "$LEASED" 4
    "$LEASE_TOOL" release --token "$POSTER_TOKEN" >/dev/null
    POSTER_TOKEN=''
    wait_for_guard "$LEASED"
    has_all_caches "$LEASED" || fail 'release cleaned a cache below SIMLEASE_POSTER_CACHE_MIN'

    # In the background after release, at most once every SIMLEASE_POSTER_SWEEP_INTERVAL.
    fake_poster_device "$IDLE" 'iPhone Idle' 1 1024
    POSTER_LEASE="$("$LEASE_TOOL" acquire --owner posters --ttl 30 --json)"
    SIMLEASE_POSTER_CLEAN=1 SIMLEASE_POSTER_SWEEP_INTERVAL=0 "$LEASE_TOOL" release --token "$(jq -r '.token' <<<"$POSTER_LEASE")" >/dev/null
    for _ in $(seq 1 100); do
        ! has_caches "$IDLE" && break
        sleep 0.1
    done
    lockf -t 15 "${SIMLEASE_DIR}/locks/poster-cache-sweep.lock" true || fail 'the background poster sweep did not finish'
    ! has_caches "$IDLE" || fail 'release did not clean an idle Simulator in the background'
    kept_the_rest "$IDLE" || fail 'the background poster sweep deleted something that is not a wallpaper cache'
    grep -q 'sweep$' "$POSTER_LOG" || fail 'the background poster sweep did not log under "sweep"'
    grep -q $'\t'"${IDLE}"$'\tiPhone Idle\t' "$POSTER_LOG" || fail 'the background poster sweep did not log what it cleaned'
    has_all_caches "$BOOTED" || fail 'the background poster sweep touched a booted Simulator'
    has_all_caches "$PINNED" || fail 'the background poster sweep touched a pinned Simulator'
    fake_poster_cache "$IDLE" 1024
    POSTER_LEASE="$("$LEASE_TOOL" acquire --owner posters --ttl 30 --json)"
    SIMLEASE_POSTER_CLEAN=1 SIMLEASE_POSTER_SWEEP_INTERVAL=1h "$LEASE_TOOL" release --token "$(jq -r '.token' <<<"$POSTER_LEASE")" >/dev/null
    sleep 2
    has_all_caches "$IDLE" || fail 'a background poster sweep ran again within SIMLEASE_POSTER_SWEEP_INTERVAL'

    # The tests' fake Simulators never reach the real device folders.
    [[ "$(SIMLEASE_TEST_SIMULATOR_DEVICES_DIR='' "$LEASE_TOOL" clean-posters --dry-run)" == Skipped:* ]] \
        || fail 'clean-posters ran with fake Simulators and no fake device folders'
)

printf 'simulator lease tests passed\n'
