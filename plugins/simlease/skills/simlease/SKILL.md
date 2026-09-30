---
name: simlease
description: Automatically coordinate iOS Simulator and Android emulator access for every mobile task that builds, tests, installs, launches, screenshots, interacts with, changes, boots, or shuts down a Simulator or emulator. Always use before xcodebuild Simulator destinations, xcrun simctl, XcodeBuildMCP Simulator tools, serve-sim, flutter run on a Simulator or emulator, emulator boots, or adb commands aimed at an emulator, even when the user does not mention SimLease.
---

# SimLease

Use the bundled `scripts/simlease` executable, resolved relative to the directory containing this `SKILL.md`. If `simlease` on `PATH` reports a newer version (`simlease --version`), use that one instead, so every agent on the Mac runs the same version.

## Preflight

Before the first device operation in a task, run `scripts/preflight`. If it fails, report the missing dependency and continue only with work that does not touch a device. If it warns that simslim is too old, tell the user; leasing still works.

## iOS Simulator workflow

1. Inspect ownership with `scripts/simlease status --json` when other device activity is possible.
   A device with `state: "free"` stays available when `serveSimActive` is true. An existing `serve-sim` helper is reusable infrastructure, not a lease or ownership claim.
2. Acquire before touching a Simulator. Save the token to a file in your scratch folder:

   ```bash
   scripts/simlease acquire \
     --owner '<task-or-agent-name>' \
     --purpose '<short purpose>' \
     --wait 900 \
     --boot-if-needed \
     --token-file '<scratch>/sim.token' \
     --json
   ```

   Before acquiring, tell the user `🔒 Reserving an iOS Simulator for this task…`. If acquisition waits, say `⏳ All matching Simulators are busy. I'm waiting for one to become free.`
   Never pipe the acquire output through `tail` or `head`: a lost token blocks the device until the lease expires.
3. SimLease slims the Simulator with the shared simslim profile. If the app needs services the profile turns off (widgets, speech, contacts, HealthKit), add `--keep-services <categories>` to acquire. Never run simslim commands that change a device (`on`, `off`, `watch`, `clone`, `repair-clone`, `erase`, `delete`, `disk-clean`, `boot`, `shutdown`, `rename`). Read-only ones are fine (`list`, `profiles`, `status`, `verify`, `doctor`, `measure`, `size`, `top --json`, `disk-plan`). To check features, run `scripts/simlease exec --token-file '<scratch>/sim.token' -- sh -c 'simslim doctor "$SIMULATOR_UDID" --requires <features>'`.
4. Use only the leased UDID. Never select `booted`, a device name, or automatic Simulator discovery.
5. Run commands through the lease. Put lease variables inside single-quoted `sh -c '…'`, so the lease sets them, not the calling shell:

   ```bash
   scripts/simlease exec --token-file '<scratch>/sim.token' -- sh -c '
     xcodebuild -scheme App -destination "id=$SIMULATOR_UDID" -derivedDataPath "$DERIVED_DATA_PATH" test
   '
   ```

6. `exec` keeps the lease alive while its command runs. For work outside `exec`, renew by hand: `scripts/simlease renew --token-file '<scratch>/sim.token' --ttl 3600`.
7. Release in cleanup, including after failures: `scripts/simlease release --token-file '<scratch>/sim.token'`.

After acquisition, tell the user which named Simulator is reserved. If `bootedBySimLease` is true, also say `🚀 Started <device> because every running Simulator was busy.` After cleanup, confirm that it was released. If release reports `shutDown: true`, say `💤 Shut down <device> to release its RAM.` Never expose the lease token in commentary or the final response.

## Android emulator workflow

1. Acquire: `scripts/simlease acquire --avd '<AVD>' --owner '<task>' --wait 900 --token-file '<scratch>/emu.token' --json`. This boots your own read-only instance of the AVD on a free port. List AVDs with `emulator -list-avds`.
2. Run commands through the lease:
   - `scripts/simlease exec --token-file '<scratch>/emu.token' -- adb …` (adb reads `ANDROID_SERIAL`)
   - `-- sh -c 'flutter run -d "$ANDROID_SERIAL"'`
   - The gRPC port is `$ANDROID_EMULATOR_GRPC_PORT`.
3. Use `--writable` only when the task must change the AVD itself. Pass extra emulator flags with `--emulator-args "…"`.
4. Release when done. Release stops the emulator.

Never boot an emulator, or aim `adb` or `flutter` at one, outside a lease. Physical Android devices are not leased: address them with `adb -s <serial>`.

## Tool-specific rules

- For XcodeBuildMCP, set `simulatorId` to the leased UDID before every Simulator tool call. Use the returned `derivedDataPath` for builds when the tool supports it.
- For `serve-sim`, use only the leased UDID. Reuse an existing helper when `serveSimAlreadyRunning` is true, and leave that inherited helper running during cleanup. Otherwise start one for that UDID, and stop only the helper started by the current task. Never stop a helper while another lease owns its Simulator.
- Pinned Simulators (`~/.config/simlease/pinned`) hold a sign-in or seeded media. Lease one only with `--device <UDID>`, and only when the task needs that state.
- Never run commands that hit every device, even inside a lease: `simctl … all`, `simctl … booted`, `killall Simulator`, `killall qemu-system…`, a `pkill` that doesn't name your port or serial, or `adb kill-server`.
- If all matching devices are leased, wait or continue other work. Never take over another lease.
- With `--boot-if-needed`, SimLease checks memory pressure and the booted-device cap before it starts a shutdown Simulator. If either check fails, explain that it is waiting for an existing lease.
- SimLease shuts down only a Simulator that it started for the current lease. Never manually shut down a Simulator that was already running.
- Devices keep other projects' apps and data. Install your own build, and never wipe data you did not create.

## Failure handling

- If acquisition fails, inspect `status`. Do not bypass SimLease.
- If a command fails, release the lease before reporting completion.
- If you lose the token, wait for the lease to expire, or ask the user, before interfering with the guard process.
- SimLease coordinates cooperating clients. It cannot stop software that bypasses it.
