---
name: simlease
description: Automatically coordinate iOS Simulator access for every iOS or iPadOS task that builds, tests, installs, launches, screenshots, interacts with, changes, boots, or shuts down a Simulator. Always use before xcodebuild Simulator destinations, xcrun simctl, XcodeBuildMCP Simulator tools, or serve-sim, even when the user does not mention SimLease.
---

# SimLease

Use the bundled `scripts/simlease` executable as the source of truth. Resolve both scripts relative to the directory containing this `SKILL.md`; do not assume `simlease` is already on `PATH`.

## Preflight

Before the first simulator operation in a task, run `scripts/preflight`. If it fails, report the missing dependency and continue only with work that does not touch a simulator.

## Lease workflow

1. Inspect ownership with `scripts/simlease status --json` when existing simulator activity is possible.
   A device with `state: "free"` remains available when `serveSimActive` is true. An existing `serve-sim` helper is reusable infrastructure, not a lease or ownership claim.
2. Acquire before touching a simulator:

   ```bash
   scripts/simlease acquire \
     --owner '<task-or-agent-name>' \
     --purpose '<short purpose>' \
     --ttl 3600 \
     --wait 120 \
     --boot-if-needed \
     --json
   ```

   Tell the user `🔒 Reserving an iOS Simulator for this task…` before acquisition. If acquisition waits, say `⏳ All matching Simulators are busy. I’m waiting for one to become free.`

3. Retain the returned `token`, `udid`, and `derivedDataPath` for the current task. Treat the token as a secret and never commit or persist it in the project.
4. Use only the leased UDID. Never select `booted`, a device name, or automatic simulator discovery after acquisition.
5. Run shell operations through the lease when possible:

   ```bash
   scripts/simlease exec --token '<token>' -- \
     xcodebuild -scheme App \
       -destination 'id=<udid>' \
       -derivedDataPath '<derivedDataPath>' \
       test
   ```

6. Renew before a long operation with `scripts/simlease renew --token '<token>' --ttl 3600`.
7. Release in cleanup, including after failures: `scripts/simlease release --token '<token>'`.

After acquisition, tell the user which named Simulator is reserved. If `bootedBySimLease` is true, also say `🚀 Started <device> because every running Simulator was busy.` After cleanup, confirm that it was released; if release reports `shutDown: true`, say `💤 Shut down <device> to release its RAM.` Do not expose the lease token in commentary or the final response.

## Tool-specific rules

- For XcodeBuildMCP, set `simulatorId` to the leased UDID before every simulator tool call. Use the returned `derivedDataPath` for builds when the tool supports it.
- For `serve-sim`, use only the leased UDID. Reuse an existing helper when `serveSimAlreadyRunning` is true and leave that inherited helper running during cleanup. Otherwise start one for that UDID and stop only the helper started by the current task. Never stop a helper while another lease owns its simulator.
- For direct `xcrun simctl`, pass the exact leased UDID.
- Do not run simulator-global destructive commands while another lease may exist.
- If all matching simulators are leased, wait or continue non-simulator work. Never take over another lease.
- With `--boot-if-needed`, SimLease measures memory pressure and the safe booted-device cap. It starts one shutdown Simulator only when both checks pass. Otherwise, explain that it is waiting for an existing lease.
- SimLease shuts down only a Simulator that it started for the current lease. Never manually shut down a Simulator that was already running.
- A previously started Simulator or `serve-sim` helper is eligible for normal acquisition. Prefer leasing an already booted free device before allowing `--boot-if-needed` to start another one.

## Failure handling

- If acquisition fails, inspect `status`; do not bypass SimLease.
- If a command fails, release the lease before reporting completion.
- If the agent loses the token, wait for expiry or ask the user before interfering with the guard process.
- Remember that SimLease coordinates cooperating clients; it cannot stop software that bypasses it.
