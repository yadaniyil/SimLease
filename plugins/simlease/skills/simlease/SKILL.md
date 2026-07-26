---
name: simlease
description: Coordinate booted iOS Simulators across concurrent Codex agents with exclusive leases. Use before any simulator build, test, install, launch, screenshot, UI interaction, permission change, media injection, shutdown, XcodeBuildMCP simulator operation, or serve-sim command when multiple tasks or agents may share the same Mac.
---

# SimLease

Use the bundled `scripts/simlease` executable as the source of truth. Resolve both scripts relative to the directory containing this `SKILL.md`; do not assume `simlease` is already on `PATH`.

## Preflight

Before the first simulator operation in a task, run `scripts/preflight`. If it fails, report the missing dependency and continue only with work that does not touch a simulator.

## Lease workflow

1. Inspect ownership with `scripts/simlease status --json` when existing simulator activity is possible.
2. Acquire before touching a simulator:

   ```bash
   scripts/simlease acquire \
     --owner '<task-or-agent-name>' \
     --purpose '<short purpose>' \
     --ttl 3600 \
     --wait 60 \
     --json
   ```

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

## Tool-specific rules

- For XcodeBuildMCP, set `simulatorId` to the leased UDID before every simulator tool call. Use the returned `derivedDataPath` for builds when the tool supports it.
- For `serve-sim`, start and stop only the leased UDID. Never stop another task's server.
- For direct `xcrun simctl`, pass the exact leased UDID.
- Do not run simulator-global destructive commands while another lease may exist.
- If all matching simulators are leased, wait or continue non-simulator work. Never take over another lease.
- If status reports `unmanaged-serve-sim`, do not adopt it unless the user explicitly confirms a controlled migration; only then use `--allow-active-serve-sim`.

## Failure handling

- If acquisition fails, inspect `status`; do not bypass SimLease.
- If a command fails, release the lease before reporting completion.
- If the agent loses the token, wait for expiry or ask the user before interfering with the guard process.
- Remember that SimLease coordinates cooperating clients; it cannot stop software that bypasses it.
