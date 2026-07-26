# SimLease

SimLease is an experimental macOS command-line coordinator for sharing booted iOS Simulators between concurrent development agents.

The current implementation is a standalone Bash CLI. It uses macOS `lockf` kernel locks as the source of truth, keeps human-readable JSON lease metadata, and runs a small guard process for each active lease. It does not use a database and does not depend on XcodeBuildMCP.

## Current status

This repository contains the working prototype extracted from the Gallery Compressor iOS project. The lease engine and its contention tests are implemented. Homebrew packaging, the Codex plugin wrapper, release automation, and public documentation are not implemented yet.

## Requirements

- macOS with Xcode command-line tools
- Bash
- `jq`
- `lockf`, `shasum`, and `uuidgen` from macOS
- At least one booted, available iOS Simulator for normal use

## Try it locally

```bash
./bin/simlease status

LEASE_JSON="$(./bin/simlease acquire \
  --owner "agent-one" \
  --purpose "Test the settings screen" \
  --ttl 3600 \
  --json)"

TOKEN="$(printf '%s' "$LEASE_JSON" | jq -r '.token')"

./bin/simlease exec --token "$TOKEN" -- sh -c '
  xcodebuild -project Example.xcodeproj \
    -scheme Example \
    -destination "id=$SIMULATOR_UDID" \
    -derivedDataPath "$DERIVED_DATA_PATH" \
    build
'

./bin/simlease release --token "$TOKEN"
```

`simlease exec` validates and renews the lease, then exports:

- `SIMULATOR_UDID`
- `SIMULATOR_NAME`
- `DERIVED_DATA_PATH`
- `SIMLEASE_TOKEN`

## Commands

```text
simlease acquire --owner NAME [--purpose TEXT] [--device UUID]
                 [--ttl SECONDS] [--wait SECONDS] [--json]
simlease status [--json]
simlease renew --token TOKEN [--ttl SECONDS] [--json]
simlease release --token TOKEN [--json]
simlease exec --token TOKEN -- COMMAND [ARG ...]
```

## How coordination works

1. SimLease discovers booted simulators using `simctl`.
2. Each simulator UUID has its own `lockf` lock file.
3. Acquisition starts a guard process that holds that lock for the lease lifetime.
4. JSON metadata records the owner, purpose, expiry, workspace, and guard PID.
5. A second cooperating process cannot acquire the same kernel lock.
6. Release signals the guard; expiry or a crashed guard also makes the simulator available again.

Runtime state defaults to `${TMPDIR}/simlease`. Override it with `SIMLEASE_DIR` when necessary. Every process that needs to coordinate must use the same state directory.

## Important limitation

SimLease coordinates cooperating clients. It cannot prevent a process from bypassing SimLease and calling `xcrun simctl`, `xcodebuild`, XcodeBuildMCP, or Simulator directly. Agent integrations are therefore responsible for acquiring a lease before any simulator operation and using only the leased UUID.

See [docs/codex-integration.md](docs/codex-integration.md) for the current Codex instruction template.

## Tests

```bash
./tests/simlease-tests.sh
```

The test suite covers simultaneous contention, multiple simulators, overflow refusal, renewal, release, expiry, invalid tokens, unmanaged serve-sim detection, and crashed guard cleanup.

## Planned distribution

The intended public distribution has two layers:

- A standalone `simlease` CLI installed through Homebrew for terminals, CI, and different agent products.
- A thin Codex plugin that bundles or invokes the CLI and teaches Codex when to acquire, renew, and release leases.

An MCP interface may be added later, but it is not required for the lease engine.
