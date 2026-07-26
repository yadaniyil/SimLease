<div align="center">
  <img src="plugins/simlease/assets/simlease-icon.png" alt="SimLease icon" width="160">

  <h1><strong>SimLease</strong></h1>

  <p>
    <strong>Safe, conflict-free iOS Simulator sharing for concurrent coding agents.</strong>
    <br>
    Kernel-backed leases, isolated Derived Data, and zero server infrastructure.
  </p>
</div>

<br>

SimLease safely shares booted iOS Simulators between concurrent coding agents on the same Mac. It uses macOS `lockf` kernel locks as the source of truth, keeps human-readable JSON lease metadata, and gives each workspace and simulator an isolated Derived Data path.

The repository ships both a Codex marketplace plugin and a standalone Bash CLI. No database or MCP server is required.

## Install the Codex plugin

Give Codex this prompt:

> Install the SimLease plugin from `https://github.com/yadaniyil/SimLease`, then use it for every iOS Simulator operation.

Codex can perform the equivalent manual installation:

```bash
codex plugin marketplace add yadaniyil/SimLease --ref main
codex plugin add simlease@simlease
```

Start a new Codex task after installation so the `simlease` skill is loaded. Open `/hooks` once and trust the SimLease hook. The plugin then activates automatically for iOS Simulator work and blocks normal Codex tool calls that bypass a lease. The plugin bundles the CLI; it does not require a separate Homebrew install or expect `simlease` on `PATH`.

For local development, install directly from this checkout:

```bash
codex plugin marketplace add "$(pwd)"
codex plugin add simlease@simlease
```

## Install the standalone CLI

```bash
git clone https://github.com/yadaniyil/SimLease.git
cd SimLease
./scripts/install.sh
```

The installer runs a dependency preflight and installs to `~/.local/bin/simlease`. Choose another prefix with `./scripts/install.sh --prefix /usr/local`.

## Requirements

- macOS with Xcode command-line tools
- Bash
- `jq`
- `lockf`, `shasum`, and `uuidgen` from macOS
- At least one available iOS Simulator device; SimLease can boot one when memory permits

Check a machine without acquiring a lease:

```bash
./plugins/simlease/skills/simlease/scripts/preflight
```

## CLI usage

```bash
LEASE_JSON="$(./bin/simlease acquire \
  --owner "agent-one" \
  --purpose "Test the settings screen" \
  --ttl 3600 \
  --boot-if-needed \
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

Available commands:

```text
simlease acquire --owner NAME [--purpose TEXT] [--device UUID]
                 [--ttl SECONDS] [--wait SECONDS] [--boot-if-needed] [--json]
simlease status [--json]
simlease renew --token TOKEN [--ttl SECONDS] [--json]
simlease release --token TOKEN [--json]
simlease exec --token TOKEN -- COMMAND [ARG ...]
```

`simlease exec` validates and renews the lease, then exports `SIMULATOR_UDID`, `SIMULATOR_NAME`, `DERIVED_DATA_PATH`, and `SIMLEASE_TOKEN`.

## How coordination works

1. SimLease discovers booted simulators using `simctl`.
2. Each simulator UUID has its own `lockf` lock file.
3. Acquisition starts a guard process that holds the lock for the lease lifetime.
4. JSON metadata records the owner, purpose, expiry, workspace, and guard PID.
5. A second cooperating process cannot acquire the same kernel lock.
6. When every running Simulator is busy, `--boot-if-needed` checks macOS memory pressure and a RAM-derived pool limit before starting one more device.
7. Release signals the guard; expiry or stale-lease cleanup makes the simulator available again.
8. If SimLease started that device, cleanup shuts it down to return its RAM. Devices that were already running are never shut down automatically.

By default, a new Simulator requires at least 4 GB and 15% free memory. The pool cap is one booted Simulator below 16 GB total RAM, two below 32 GB, and three at 32 GB or more. Advanced users can tune `SIMLEASE_MIN_FREE_MEMORY_MB`, `SIMLEASE_MIN_FREE_MEMORY_PERCENT`, and `SIMLEASE_MAX_BOOTED_SIMULATORS`.

Runtime state defaults to `${TMPDIR}/simlease`. Override it with `SIMLEASE_DIR` when necessary. Every cooperating process must use the same state directory.

## Automatic Codex protection

The skill is eligible for implicit use whenever Codex recognizes iOS Simulator work. A bundled `PreToolUse` hook also guards direct `simctl`, Simulator `xcodebuild`, `serve-sim`, and Simulator MCP calls. It tells the agent to acquire a lease instead of silently letting one task interfere with another.

Codex requires each user to review and trust a newly installed or changed hook with `/hooks`. This is a one-time safety step for each hook version.

## Limitations

SimLease coordinates cooperating clients. Its Codex hook protects normal hooked tool calls, but it cannot police Xcode, Terminal, another agent product, disabled hooks, or specialized tool paths that do not participate in Codex hooks. Those clients must use the standalone CLI policy and the exact leased UUID.

A live `serve-sim` helper without a matching lease is reported as `unmanaged-serve-sim` and blocks acquisition. `--allow-active-serve-sim` is reserved for an explicitly approved migration of that existing session.

## Development and releases

Run all local checks:

```bash
bash -n bin/simlease plugins/simlease/skills/simlease/scripts/* tests/simlease-tests.sh
./tests/plugin-tests.py
./tests/simlease-tests.sh
python3 /path/to/plugin-creator/scripts/validate_plugin.py plugins/simlease
```

GitHub Actions repeats syntax, ShellCheck, plugin, and lease-engine tests on macOS. Tags matching the manifest version, such as `v0.1.0`, create a GitHub release containing a plugin archive, standalone CLI, and SHA-256 checksums.

See [CONTRIBUTING.md](CONTRIBUTING.md), [SECURITY.md](SECURITY.md), and [docs/codex-integration.md](docs/codex-integration.md).

## License

MIT © 2026 Danny Yako
