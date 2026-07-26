# Codex integration draft

The following policy can be adapted for a project's `AGENTS.md`. It is an instruction layer around the `simlease` CLI; the CLI and its kernel lock perform the actual coordination.

## Acquire an exclusive simulator lease

Before any simulator build, install, launch, test, screenshot, permission change, media injection, UI interaction, shutdown, or serve-sim command, acquire a lease:

```bash
LEASE_JSON="$(simlease acquire \
  --owner '<task-or-agent-name>' \
  --purpose '<short description>' \
  --ttl 3600 \
  --json)"
SIMULATOR_UUID="$(printf '%s' "$LEASE_JSON" | jq -r '.udid')"
SIMULATOR_LEASE_TOKEN="$(printf '%s' "$LEASE_JSON" | jq -r '.token')"
DERIVED_DATA_PATH="$(printf '%s' "$LEASE_JSON" | jq -r '.derivedDataPath')"
```

Rules:

- Never touch a simulator before successfully acquiring its lease.
- If all matching simulators are leased, wait or continue non-simulator work. Never take over another lease.
- Use only the exact leased UUID. Do not use `booted`, a device name, or automatic simulator selection after acquisition.
- Renew before another long operation with `simlease renew --token "$SIMULATOR_LEASE_TOKEN"`.
- Prefer `simlease exec --token "$SIMULATOR_LEASE_TOKEN" -- <command>` for shell commands.
- For XcodeBuildMCP, set `simulatorId` to the leased UUID before any simulator tool call.
- Do not run simulator-global destructive commands while other agents may be working.
- Stop serve-sim only for the leased simulator UUID.
- Always release at the end, including after failures.
- Inspect current ownership with `simlease status`.

A live serve-sim helper without a matching lease is reported as `unmanaged-serve-sim` and blocks acquisition. `--allow-active-serve-sim` is intended only for an explicit, controlled migration of that existing session.
