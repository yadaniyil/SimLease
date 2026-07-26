# Codex integration policy

The Codex plugin already packages this policy as the `simlease` skill. The following version is for teams that want to reinforce the same behavior in a project's `AGENTS.md` or use the standalone CLI with another agent product. The CLI and its kernel lock perform the actual coordination.

When the plugin is installed, use the executable bundled beside its `SKILL.md`. When the standalone CLI is installed, use `simlease` from `PATH` as shown below.

## Acquire an exclusive simulator lease

Before any simulator build, install, launch, test, screenshot, permission change, media injection, UI interaction, shutdown, or serve-sim command, acquire a lease:

```bash
LEASE_JSON="$(simlease acquire \
  --owner '<task-or-agent-name>' \
  --purpose '<short description>' \
  --ttl 3600 \
  --wait 120 \
  --boot-if-needed \
  --json)"
SIMULATOR_UUID="$(printf '%s' "$LEASE_JSON" | jq -r '.udid')"
SIMULATOR_LEASE_TOKEN="$(printf '%s' "$LEASE_JSON" | jq -r '.token')"
DERIVED_DATA_PATH="$(printf '%s' "$LEASE_JSON" | jq -r '.derivedDataPath')"
```

Rules:

- Never touch a simulator before successfully acquiring its lease.
- If all matching simulators are leased, wait or continue non-simulator work. Never take over another lease.
- Let `--boot-if-needed` decide whether the Mac has enough free memory to start one more Simulator. If not, wait for an existing lease.
- Use only the exact leased UUID. Do not use `booted`, a device name, or automatic simulator selection after acquisition.
- Renew before another long operation with `simlease renew --token "$SIMULATOR_LEASE_TOKEN"`.
- Prefer `simlease exec --token "$SIMULATOR_LEASE_TOKEN" -- <command>` for shell commands.
- For XcodeBuildMCP, set `simulatorId` to the leased UUID before any simulator tool call.
- Do not run simulator-global destructive commands while other agents may be working.
- Stop serve-sim only for the leased simulator UUID.
- Always release at the end, including after failures.
- Release shuts down a Simulator only when SimLease started it for that lease. A previously running device stays running.
- Inspect current ownership with `simlease status`.

A live serve-sim helper without a matching lease is reported as `unmanaged-serve-sim` and blocks acquisition. `--allow-active-serve-sim` is intended only for an explicit, controlled migration of that existing session.
