# Agent policy for shared devices

This is the full version of the rules in the README's [Instructions for your agents](../README.md#instructions-for-your-agents). Use it in `~/.claude/CLAUDE.md`, `~/.codex/AGENTS.md`, a project's `AGENTS.md`, or the rules of any other agent. The Codex plugin already ships these rules as its `simlease` skill.

The CLI and its kernel locks do the actual coordination, and the guard hooks catch the common mistakes. These rules cover what the hooks can't see.

With the Codex plugin, use the executable bundled beside its `SKILL.md`. With the standalone CLI, use `simlease` from `PATH`. If both are installed, prefer the standalone CLI, so every agent on the Mac runs the same version.

## Take a lease before touching a device

Lease a device before any of these:
- a Simulator build, install, launch, test or screenshot
- a permission change, media injection or UI interaction
- a shutdown or `serve-sim` command
- an emulator boot, or `adb` or `flutter` aimed at an emulator

iOS:

```bash
simlease acquire --owner '<task-or-agent>' --purpose '<short description>' \
  --boot-if-needed --wait 900 --token-file "<scratch>/sim.token" --json
```

Android:

```bash
simlease acquire --avd '<AVD>' --owner '<task-or-agent>' --purpose '<short description>' \
  --wait 900 --token-file "<scratch>/emu.token" --json
```

Why `--token-file`: the token is the only way to renew or release a lease. If it is lost, for example because the output was piped through `tail` or `head`, the device stays blocked until the lease expires.

## Work inside the lease

```bash
simlease exec --token-file "<scratch>/sim.token" -- sh -c '
  xcodebuild -scheme App -destination "id=$SIMULATOR_UDID" -derivedDataPath "$DERIVED_DATA_PATH" test
'
simlease exec --token-file "<scratch>/emu.token" -- sh -c 'flutter run -d "$ANDROID_SERIAL"'
simlease exec --token-file "<scratch>/emu.token" -- adb logcat -d
```

- **Quote the variables.** Put commands that use `$SIMULATOR_UDID`, `$DERIVED_DATA_PATH` or `$ANDROID_SERIAL` inside single-quoted `sh -c '…'`. Unquoted, the calling shell expands them to nothing before the lease sets them.
- **Build into the lease's Derived Data.** Pass `$DERIVED_DATA_PATH` as given, and never hard-code it: for a project on an external disk it is on that disk (`<volume>/simlease-derived-data/…`), so builds don't fill the internal one. `simlease prune` lists old folders there; it deletes nothing without `--delete`.
- **Stay on your device.** Use only the leased UDID or serial. Never `booted`, a device name, a hard-coded UDID, emulator-5554, or automatic device selection.
- **Long runs are fine.** `exec` keeps the lease alive while its command runs. Anything run outside `exec` keeps the device only until the TTL passes; then SimLease stops the device.
- **MCP tools.** For XcodeBuildMCP or another Simulator tool, pass the leased UDID in every call.
- **serve-sim.** Stop a helper only for your leased UDID. Leave one running if it existed before your lease (`serveSimAlreadyRunning: true`).

## Slim Simulators

- SimLease slims every leased Simulator with one shared simslim profile. Never run simslim commands that change a device: `on`, `off`, `watch`, `clone`, `repair-clone`, `erase`, `delete`, `disk-clean`, `boot`, `shutdown`, `rename`. Slimming persists on the device, so another project's app would lose services. `watch` slims every Simulator as it boots, other agents' too, and `repair-clone` can keep another agent's Simulator shut down.
- Read-only simslim commands are fine: `list`, `profiles`, `status`, `verify`, `doctor`, `measure`, `size`, `top --json`, `disk-plan`.
- If the app needs more than the profile keeps (widgets, speech, contacts, HealthKit), acquire with `--keep-services <categories>`. `simslim profiles` lists the categories.
- To check that the leased Simulator has the features the app needs, run `simslim doctor` inside the lease: `simlease exec --token-file "<scratch>/sim.token" -- sh -c 'simslim doctor "$SIMULATOR_UDID" --requires <features>'`. `simslim doctor --list` lists the features.

## Pinned Simulators

Simulators listed in `~/.config/simlease/pinned` hold a sign-in or seeded media. Lease one only with `--device <UDID>`, and only when the task needs that state.

## Emulators

- A lease boots your own instance, read-only by default, so leases share AVDs freely and never change them.
- Use `--writable` only when the task must change the AVD itself, for example signing in an account.
- Extra emulator flags (camera, GPU) go in `--emulator-args`. The gRPC port for camera injection is `$ANDROID_EMULATOR_GRPC_PORT`.
- Physical Android devices aren't leased: address them with `adb -s <serial>`.

## Be a good neighbour

- If every device is leased, wait (`--wait`) or do other work. Never take over another lease, and never stop a device you didn't lease.
- Never run commands that hit every device: `simctl … all`, `killall Simulator`, `killall qemu-system…`, a `pkill` without your port or serial, or `adb kill-server`.
- Devices keep other projects' apps and data. Install your own build. Never rely on data you didn't create, and never wipe it.
- Give local servers and helpers their own ports. A `pkill -f` pattern must name your worktree path or your device serial.
- Sub-agents that run in parallel each take their own lease and their own scratch folder. They never share token files, logs or build settings.
- Always release, including after failures: `simlease release --token-file …`. Release stops the device if SimLease started it.
- `simlease status` shows who holds what.
