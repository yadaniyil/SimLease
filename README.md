<div align="center">
  <img src="plugins/simlease/assets/simlease-icon.png" alt="SimLease icon" width="160">

  <h1><strong>SimLease</strong></h1>

  <p>
    <strong>Conflict-free iOS Simulators and Android emulators for concurrent coding agents.</strong>
    <br>
    Kernel-backed leases, slim Simulators, isolated Derived Data, and zero server infrastructure.
  </p>
</div>

<br>

Run several coding agents on one Mac: Claude Code, Codex, or anything that can run a shell command. Each agent leases its own iOS Simulator or Android emulator, so builds, tests and app runs never land on another agent's device.

SimLease is one Bash CLI plus an optional guard hook. It uses macOS `lockf` kernel locks as the source of truth, keeps human-readable JSON lease metadata, and needs no database, daemon or MCP server.

- **iOS Simulators.** Every lease gets one Simulator to itself, with its own Derived Data path, on the project's own disk when the project is on an external one. Busy pool? SimLease boots another Simulator when memory allows.
- **Slim Simulators.** With [simslim](https://github.com/mobai-app/simslim) installed, every leased Simulator is trimmed to the services apps need: about 0.9 GB instead of 4 GB, so twice as many fit.
- **Android emulators.** Every lease boots its own instance of an AVD on a free port. Instances run read-only by default, so many agents can share one AVD without changing it.
- **Guard hooks.** Claude Code and Codex hooks block device commands that don't hold a lease, and commands that would hit every agent's devices at once.

## Contents

- [Install](#install)
- [Quick start](#quick-start)
- [Commands](#commands)
- [Derived Data](#derived-data)
- [Slim Simulators](#slim-simulators)
- [Android emulators](#android-emulators)
- [Guard hooks](#guard-hooks)
- [Instructions for your agents](#instructions-for-your-agents)
- [How coordination works](#how-coordination-works)
- [Configuration](#configuration)
- [Requirements](#requirements)
- [Limitations](#limitations)
- [Development and releases](#development-and-releases)

## Install

### CLI (every agent)

```bash
git clone https://github.com/yadaniyil/SimLease.git
cd SimLease
./scripts/install.sh
```

The installer runs a dependency preflight and installs `~/.local/bin/simlease` and the guard at `~/.local/share/simlease/hooks/`. It also creates `~/.config/simlease/simslim-profile.json` and `~/.config/simlease/pinned` if they don't exist; it never overwrites them. Choose another prefix with `--prefix /usr/local`.

Optional: `brew install mobai-app/tap/simslim` to slim every leased Simulator. SimLease needs simslim 0.6.1 or newer; 0.11 is recommended (much faster slimming).

### Claude Code

```bash
./scripts/install.sh --with-claude-hook
```

This also installs the guard as `~/.claude/hooks/simlease_guard_claude.py`. Register it once in `~/.claude/settings.json`:

```json
{
  "hooks": {
    "PreToolUse": [
      {
        "matcher": "Bash|mcp__.*([Xx]code|[Ss]imulator|serve[_-]sim).*",
        "hooks": [
          {
            "type": "command",
            "command": "python3 \"$HOME/.claude/hooks/simlease_guard_claude.py\"",
            "timeout": 5,
            "statusMessage": "Checking device lease"
          }
        ]
      }
    ]
  }
}
```

Then add the [agent instructions](#instructions-for-your-agents) to `~/.claude/CLAUDE.md`, so every project knows the flow.

### Codex

The easiest option is [Open SimLease in Codex](https://yadaniyil.github.io/SimLease/install/). Press Send when Codex opens, then follow the one-time hook trust instruction. Or install the marketplace plugin yourself:

```bash
codex plugin marketplace add yadaniyil/SimLease --ref main
codex plugin add simlease@simlease
```

Start a new Codex task so the `simlease` skill loads, then open `/hooks` once and trust the SimLease hook. Codex asks again whenever the hook changes. The plugin bundles its own copy of the CLI. If you also installed the standalone CLI, tell Codex to prefer it in `~/.codex/AGENTS.md`, so every agent uses the same version.

For local development, install from this checkout: `codex plugin marketplace add "$(pwd)"`.

### Other agents

Install the CLI, and put the [agent instructions](#instructions-for-your-agents) wherever your agent reads its rules. Agents without hooks follow the rules on trust.

## Quick start

iOS:

```bash
simlease acquire --owner agent-one --purpose "Test the settings screen" \
  --boot-if-needed --wait 900 --token-file /tmp/agent-one.sim --json

simlease exec --token-file /tmp/agent-one.sim -- sh -c '
  xcodebuild -project Example.xcodeproj -scheme Example \
    -destination "id=$SIMULATOR_UDID" -derivedDataPath "$DERIVED_DATA_PATH" test
'

simlease release --token-file /tmp/agent-one.sim
```

Android:

```bash
simlease acquire --avd Pixel_8 --owner agent-two --wait 900 --token-file /tmp/agent-two.emu --json
simlease exec --token-file /tmp/agent-two.emu -- sh -c 'flutter run -d "$ANDROID_SERIAL"'
simlease exec --token-file /tmp/agent-two.emu -- adb shell getprop ro.build.version.sdk
simlease release --token-file /tmp/agent-two.emu
```

Put commands that use the lease's variables inside single-quoted `sh -c '…'`. Written straight after `--`, your own shell expands `$SIMULATOR_UDID` to nothing before the lease sets it. `adb` needs no variable: it reads `ANDROID_SERIAL` itself.

## Commands

```text
simlease acquire --owner NAME [options]                         iOS Simulator
simlease acquire --avd NAME --owner NAME [options]              Android emulator
simlease status [--json]
simlease renew   (--token TOKEN | --token-file PATH) [--ttl SECONDS] [--json]
simlease release (--token TOKEN | --token-file PATH) [--json]
simlease exec    (--token TOKEN | --token-file PATH) -- COMMAND [ARG ...]
simlease prune   [--dir FOLDER] [--delete]                      old Derived Data on a volume
```

Options for both platforms:

| Option | Meaning |
| --- | --- |
| `--owner NAME` | Required task or agent name, shown in `status`. |
| `--purpose TEXT` | Short description, shown in `status`. |
| `--ttl SECONDS` | Lease lifetime, default 3600. `exec` renews while its command runs. |
| `--wait SECONDS` | How long to wait for a device, default 0. |
| `--token-file PATH` | Also write the token to a private (0600) file. Refuses a file that still holds a live lease's token, so the only copy is never overwritten. |
| `--json` | Machine-readable output. |

Simulator options:

| Option | Meaning |
| --- | --- |
| `--device UUID` | Lease only this Simulator. The only way to lease a [pinned](#configuration) one. |
| `--boot-if-needed` | Boot one more Simulator when every booted one is leased and memory allows. |
| `--keep-services LIST` | simslim categories this lease also needs running, on top of the shared profile, e.g. `widgets,siri`. |

Emulator options:

| Option | Meaning |
| --- | --- |
| `--avd NAME` | The AVD to boot (implies `--android`). |
| `--writable` | Boot the AVD writable, to change the AVD itself. Waits until no other instance of it runs. |
| `--window` | Show the emulator window. The default is headless. |
| `--emulator-args "…"` | Extra emulator flags, e.g. `"-camera-back emulated -gpu swiftshader_indirect"`. |

`exec` renews the lease, exports the device variables and replaces itself with the command:

- Simulator: `SIMULATOR_UDID`, `SIMULATOR_NAME`, `DERIVED_DATA_PATH`.
- Emulator: `ANDROID_SERIAL`, `ANDROID_AVD_NAME`, `ANDROID_EMULATOR_PORT`, `ANDROID_EMULATOR_GRPC_PORT`.
- Both: `SIMLEASE_TOKEN`.

While the command runs, a background renewer extends the lease at a third of its TTL, so a long `flutter run` or test run keeps its device. The renewer stops when the command exits. Anything run outside `exec` keeps the device only until the TTL passes.

`release` stops the device when SimLease booted it: always for emulators, and for Simulators that SimLease started. `status` lists every lease, its owner and expiry, and how much room is left.

## Derived Data

Every Simulator lease has its own `DERIVED_DATA_PATH`, so two agents never build into the same folder. Pass it to `xcodebuild -derivedDataPath`.

| The project is on | `DERIVED_DATA_PATH` |
| --- | --- |
| The boot volume | `${TMPDIR}/simlease/derived-data/<key>/<UDID>` |
| Another volume, such as an external disk | `<volume>/simlease-derived-data/<key>/<UDID>` |

`<key>` is the first 12 characters of the SHA-256 of the folder `acquire` ran in, so every project, worktree and subfolder has its own. The path is fixed when the lease is acquired.

A project on an external disk keeps its Derived Data on that disk, off the internal one. SimLease works the volume out from the project folder, by device number, so any volume name works. If the folder on the volume can't be created or written (a read-only disk, for example), the lease still succeeds: it prints a warning and uses the default location.

`SIMLEASE_DERIVED_DATA_DIR=/absolute/folder` puts every project's Derived Data under that folder instead, as `<key>/<UDID>`. It moves nothing else: locks and leases stay in `SIMLEASE_DIR`, so leasing keeps working while an external disk is unplugged.

macOS empties `${TMPDIR}` by itself. Nothing empties a volume, and SimLease never deletes Derived Data on its own. Each `<key>` folder on a volume, or under `SIMLEASE_DERIVED_DATA_DIR`, holds a `simlease-project.json` that names its project. `prune` reads it:

```bash
simlease prune                                                     # the current folder's volume; lists only
simlease prune --dir /Volumes/Work/simlease-derived-data --delete
```

`prune` prints one line per folder: `stale` (the project folder is gone), `in-use` (it exists), `leased` (a lease points into it) or `unknown` (the project's parent folder is missing too: it moved, or its volume isn't mounted). Only `stale` folders are deleted, and only with `--delete`, which reports them as `deleted`. A folder without its own `simlease-project.json` is never touched.

Only builds that are given `DERIVED_DATA_PATH` use it. `flutter run`, Xcode and MCP build tools pick their own build folders unless you pass them the path.

## Slim Simulators

When `simslim` is on `PATH`, every iOS acquire makes the leased Simulator match one shared profile, `~/.config/simlease/simslim-profile.json`:

```json
{"name": "shared", "except": ["photos", "store", "icloud", "web"], "keep": []}
```

`except` lists the [simslim categories](https://github.com/mobai-app/simslim) that stay running; `keep` lists single daemons that stay running. The default keeps what most apps need: the photo library, StoreKit and push, Apple sign-in and keychain, and universal links and web sign-in.

- **Timing.** A Simulator that already matches costs a one-second check. Any other is reconfigured and rebooted slim once, in 10-25 s with simslim 0.11 or newer. Older versions take longer.
- **Why one profile.** Slimming persists on the device. A Simulator slimmed for one project must still run the next project's app, so every project shares the same profile.
- **Extra services.** A lease that needs more, such as widgets or speech, asks for them with `--keep-services widgets,siri`. The device is re-slimmed for that lease and back to the shared profile for the next lease that doesn't ask. An unknown category fails the acquire before it takes a device; `simslim profiles` lists the categories.
- **Result.** `acquire` reports `slim`: `verified` (already matched), `applied`, `failed`, `unsupported` (simslim older than 0.6.1), or `off`. After `failed` the lease still holds, the Simulator keeps its previous profile, and SimLease boots it again if simslim left it shut down.
- **Pool size.** Slim Simulators raise the pool cap: 2 booted Simulators below 16 GB of RAM, 3 below 32 GB, 4 below 64 GB, and 6 at 64 GB (without simslim: 1, 2 and 3).
- **Off switch.** `SIMLEASE_SLIM=0` turns slimming off.

Agents never run simslim commands that change a device: `on`, `off`, `watch`, `clone`, `repair-clone`, `erase`, `delete`, `disk-clean`, `boot`, `shutdown` and `rename`. The guard blocks them. Read-only ones are fine: `list`, `profiles`, `status`, `verify`, `doctor`, `measure`, `size`, `top --json` and `disk-plan`. To check that a leased Simulator still has the features an app needs, run `simslim doctor` inside the lease:

```bash
simlease exec --token-file /tmp/agent-one.sim -- sh -c 'simslim doctor "$SIMULATOR_UDID" --requires push,storekit'
```

`simslim doctor --list` lists the features.

## Android emulators

`simlease acquire --avd NAME` boots a new instance of the AVD for this lease.

- **Ports.** Each lease gets a free even console port from 5560. The emulator also uses the port above it for adb and port+3000 for gRPC. Ports in use by emulators that SimLease didn't start are skipped.
- **Read-only by default.** Many leases can run the same AVD at once, and none of them changes it. `--writable` is for changing the AVD itself, for example signing in an account; it waits until no other instance of that AVD runs. Two names for one AVD folder (two `.ini` files with the same `path=`) count as one AVD.
- **Headless.** No window unless `--window`.
- **Boots.** A boot waits for `sys.boot_completed` (up to 7 minutes, `SIMLEASE_ANDROID_BOOT_TIMEOUT_SECONDS`). A failed boot fails the acquire at once, with the last lines of the emulator log.
- **Separate pool lock.** Emulator boots are serialized under their own pool lock, so a slow boot never delays a Simulator lease. The cap is `SIMLEASE_MAX_EMULATORS` (4 at 64 GB of RAM).
- **Stopping.** Release or expiry stops the emulator.

SimLease finds the SDK through `ANDROID_SDK_ROOT`, `ANDROID_HOME` or `~/Library/Android/sdk`. Physical Android devices aren't leased: address them with `adb -s <serial>`.

## Guard hooks

The guard is a `PreToolUse` hook shared by Claude Code and Codex. It reads each Bash command and each Simulator MCP tool call.

**Needs a lease.** These are blocked unless they run through `simlease exec`:
- `xcrun simctl`
- `xcodebuild` aimed at a Simulator
- `serve-sim`
- `flutter` aimed at a Simulator UDID
- emulator boots
- `adb` or `flutter` aimed at an emulator
- `adb` device commands with no target
- Simulator MCP calls that don't name a leased UDID

**Always blocked, even inside a lease.** These hit every agent's devices:
- `simctl … all` and `simctl … booted`
- simslim commands that change a device: `on`, `off`, `watch`, `clone`, `repair-clone`, `erase`, `delete`, `disk-clean`, `boot`, `shutdown`, `rename`. Global options before the command, a full path, quotes and `$(which simslim)` don't get past it. `watch` slims every Simulator as it boots, other agents' too; `repair-clone` can keep another agent's Simulator shut down.
- `killall` of Simulators or emulators
- a `pkill` that doesn't name a port or serial
- `adb kill-server`

**Always allowed:**
- read-only calls such as `xcrun simctl list`, `adb devices` and `emulator -list-avds`
- read-only simslim commands: `list`, `profiles`, `status`, `verify`, `doctor`, `measure`, `size`, `top`, `disk-plan`, `disk-categories`, `version`, `profile`
- text searches (`grep`, `rg`, `ag`, `git grep`) that mention device commands. A device command elsewhere in the same command line is still checked.
- physical devices addressed with `adb -s <serial>`

The guard only sees command text. A script that runs `simctl` inside it passes unchecked, and a commit message that mentions a blocked command gets blocked; use `git commit -F <file>` for those.

## Instructions for your agents

Hooks catch mistakes; instructions prevent them. Paste this into `~/.claude/CLAUDE.md`, `~/.codex/AGENTS.md`, or your project's `AGENTS.md`:

```markdown
## iOS Simulators and Android emulators

Many agents share this Mac's devices. `simlease` leases every Simulator and emulator.
- iOS: `simlease acquire --owner <task> --boot-if-needed --wait 900 --token-file <scratch>/sim.token --json`.
  Run everything inside the lease, in single quotes:
  `simlease exec --token-file <scratch>/sim.token -- sh -c 'flutter run -d "$SIMULATOR_UDID"'`.
  Never use `booted` or a hard-coded UDID. Need more services? Add `--keep-services widgets,siri`.
  simlease slims every leased Simulator. Never run simslim commands that change a device (`on`, `off`,
  `watch`, `clone`, `repair-clone`, `erase`, `delete`, `disk-clean`, `boot`, `shutdown`, `rename`).
  Read-only ones are fine (`list`, `profiles`, `status`, `verify`, `doctor`, `measure`, `size`,
  `top --json`, `disk-plan`). To check features, run `simslim doctor "$SIMULATOR_UDID" --requires <features>`
  inside `simlease exec`.
- Android: `simlease acquire --avd <AVD> --owner <task> --wait 900 --token-file <scratch>/emu.token --json`
  boots your own read-only instance. Then `simlease exec --token-file … -- adb …` or
  `-- sh -c 'flutter run -d "$ANDROID_SERIAL"'`.
- `simlease release --token-file …` when done. Never pipe `acquire` through `tail` or `head`:
  a lost token blocks a device until the lease expires.
- Devices keep other agents' apps and data. Install your own build; never wipe data you didn't create.
- `simlease status` shows who holds what.
```

[docs/agent-policy.md](docs/agent-policy.md) has the longer version, with the reasons behind each rule.

## How coordination works

1. SimLease discovers booted Simulators with `simctl`. Emulator leases are named after their console port.
2. Each device has its own `lockf` lock file.
3. Acquisition submits a one-shot guard job to the user's `launchd` domain, outside the acquiring command's process tree, so the lease outlives the shell that took it.
4. The guard holds the lock for the lease lifetime. JSON metadata records the owner, purpose, expiry, workspace and launchd label.
5. A second process cannot take the same kernel lock.
6. When every running Simulator is busy, `--boot-if-needed` checks macOS memory pressure and the pool cap before starting one more.
7. Release signals the guard. Expiry, or a crashed guard, frees the device the same way.
8. Cleanup shuts down a device only if SimLease started it for that lease. Simulators that were already running are never shut down.

A new device needs at least 4 GB and 15% of memory free. Runtime state lives in `${TMPDIR}/simlease`, and versioned copies of the guard live in `${TMPDIR}/simlease-runtime`, so `launchd` can run leases acquired from TCC-protected project folders.

A previously started `serve-sim` helper doesn't reserve its Simulator. `status` reports it as `serveSimActive: true`. When the kernel lock is free, acquisition reuses that booted device and returns `serveSimAlreadyRunning: true`, so the agent knows to leave the helper running during cleanup.

## Configuration

| File or variable | Default | Meaning |
| --- | --- | --- |
| `~/.config/simlease/simslim-profile.json` | photos, store, icloud, web | The shared simslim profile. |
| `~/.config/simlease/pinned` | empty | Simulator UDIDs that automatic picks skip, one per line, `#` comments allowed. Use it for devices with state worth keeping: a signed-in account, seeded photos. |
| `SIMLEASE_SLIM` | `1` | `0` turns slimming off. |
| `SIMLEASE_MAX_BOOTED_SIMULATORS` | from RAM | The Simulator pool cap. |
| `SIMLEASE_MAX_EMULATORS` | from RAM | The emulator cap. |
| `SIMLEASE_MIN_FREE_MEMORY_MB` / `_PERCENT` | 4096 / 15 | Free memory needed to boot another device. |
| `SIMLEASE_TTL_SECONDS` | 3600 | Default lease lifetime. |
| `SIMLEASE_ANDROID_AVD` | none | AVD used when `--android` has no `--avd`. |
| `SIMLEASE_ANDROID_FIRST_PORT` / `_LAST_PORT` | 5560 / 5680 | Emulator console port range. |
| `SIMLEASE_DIR` | `${TMPDIR}/simlease` | Shared state. Every cooperating process must use the same one. |
| `SIMLEASE_DERIVED_DATA_DIR` | unset | An absolute folder for every project's [Derived Data](#derived-data). Moves nothing else. |
| `SIMLEASE_CONFIG_DIR` | `~/.config/simlease` | Where the profile and pinned list live. |

## Requirements

- macOS with Xcode command-line tools
- Bash, `jq`, `python3` (for the hooks)
- `install`, `launchctl`, `lockf`, `shasum` and `uuidgen`, which ship with macOS
- For Android: the Android SDK emulator and platform tools, and at least one AVD
- Optional: [simslim](https://github.com/mobai-app/simslim) 0.6.1 or newer for slim Simulators; 0.11 recommended (much faster slimming)

Check a machine without taking a lease:

```bash
./plugins/simlease/skills/simlease/scripts/preflight
```

The preflight also prints the simslim version. It warns below 0.11, and below 0.6.1 it says SimLease won't slim Simulators. Leasing works either way.

## Limitations

SimLease coordinates cooperating agents. The hooks cover normal tool calls in Claude Code and Codex. They can't police Xcode, a Terminal window, another agent product, a disabled hook, or a command hidden inside a script. Those must follow the same instructions and use the leased device.

Devices are shared over time. A leased Simulator or AVD may hold another project's apps and data from earlier leases. Emulators run read-only by default, so a normal lease leaves no trace on the AVD.

## Development and releases

Run every check CI runs:

```bash
bash -n bin/simlease scripts/install.sh plugins/simlease/skills/simlease/scripts/* tests/simlease-tests.sh
shellcheck bin/simlease scripts/install.sh plugins/simlease/skills/simlease/scripts/* tests/simlease-tests.sh
./tests/plugin-tests.py
./tests/hook-tests.py
./tests/claude-hook-tests.py
./tests/simlease-tests.sh
```

The lease tests use fake Simulators, fake emulators and a fake simslim in a temporary lease directory. They never touch real devices. GitHub Actions runs the same checks on macOS. A tag matching the manifest version, such as `v0.3.1`, publishes a GitHub release with the plugin archive, the standalone CLI and SHA-256 checksums.

See [CONTRIBUTING.md](CONTRIBUTING.md) and [SECURITY.md](SECURITY.md).

## License

MIT © 2026 Danny Yako
