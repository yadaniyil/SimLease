# SimLease

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

Start a new Codex task after installation so the `simlease` skill is loaded. The plugin bundles the CLI; it does not require a separate Homebrew install or expect `simlease` on `PATH`.

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
- At least one booted, available iOS Simulator for normal use

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
                 [--ttl SECONDS] [--wait SECONDS] [--json]
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
6. Release signals the guard; expiry or a crashed guard makes the simulator available again.

Runtime state defaults to `${TMPDIR}/simlease`. Override it with `SIMLEASE_DIR` when necessary. Every cooperating process must use the same state directory.

## Limitations

SimLease coordinates cooperating clients. It cannot prevent a process from bypassing SimLease and calling `xcrun simctl`, `xcodebuild`, XcodeBuildMCP, or Simulator directly. The Codex skill therefore instructs agents to acquire before any simulator operation and use only the leased UUID.

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
