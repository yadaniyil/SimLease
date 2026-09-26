#!/usr/bin/env python3
"""Claude Code PreToolUse guard: Simulator and emulator work must hold a SimLease lease.

Installed by `scripts/install.sh --with-claude-hook` to
~/.claude/hooks/simlease_guard_claude.py. It wraps the SimLease Codex guard (same
hook JSON format), which decides for Bash commands and Simulator tools, and adds:
- `flutter run|drive|test|install|attach|logs|screenshot` aimed at an iOS
  Simulator UDID (8-4-4-4-12 hex) must run through `simlease exec --token ...`.
  Physical iPhone UDIDs pass.
- Read-only `xcrun simctl list|help` is allowed without a lease.
- Tools other than Bash and Simulator tools (TaskStop reaches this hook) pass.
"""

from __future__ import annotations

import glob
import json
import os
import re
import subprocess
import sys

UPSTREAM_CANDIDATES = [
    *([os.environ["SIMLEASE_GUARD_PATH"]] if os.environ.get("SIMLEASE_GUARD_PATH") else []),
    os.path.expanduser("~/.local/share/simlease/hooks/simlease_guard.py"),
    *sorted(
        glob.glob(os.path.expanduser("~/.codex/plugins/cache/simlease/simlease/*/hooks/simlease_guard.py")),
        reverse=True,
    ),
]

SIM_UDID = r"[0-9A-Fa-f]{8}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{12}"
FLUTTER_ON_SIMULATOR = re.compile(
    r"\bflutter\s+(?:run|drive|test|install|attach|logs|screenshot)\b[^\n;&|]*?"
    r"(?:-d|--device-id)(?:\s+|=)[\"']?" + SIM_UDID
)
SIMLEASE_EXEC = re.compile(r"(?:^|[\s/'\"(])(?:simlease|scripts/simlease)\s+exec\s+--token\b")
READ_ONLY_SIMCTL = re.compile(r"\bxcrun\s+simctl\s+(?:list|help)\b")
# Cheap prefilter: only commands that could touch a device go to the upstream guard.
LOOKS_LIKE_DEVICE = re.compile(
    r"simctl|xcodebuild|serve-sim|Simulator|flutter|simslim|\badb\b|emulator|qemu|killall|pkill",
    re.IGNORECASE,
)
# The MCP half of the settings.json matcher. Only these tools need a lease.
SIMULATOR_TOOL = re.compile(r"[Xx]code|[Ss]imulator|serve[_-]sim")

FLUTTER_REASON = (
    "SimLease blocked a flutter command aimed at an iOS Simulator. Lease one first: "
    "`simlease acquire --owner <task-id> --wait 600 --boot-if-needed --token-file <file>`, then run "
    "`simlease exec --token-file <file> -- sh -c 'flutter ... -d \"$SIMULATOR_UDID\"'`, and "
    "`simlease release --token-file <file>` when done."
)


def emit(decision: str, reason: str) -> None:
    out = {"hookSpecificOutput": {"hookEventName": "PreToolUse", "permissionDecision": decision,
                                  "permissionDecisionReason": reason}}
    if decision == "deny":
        out["systemMessage"] = reason
    print(json.dumps(out))


def main() -> int:
    raw = sys.stdin.read()
    try:
        event = json.loads(raw)
    except json.JSONDecodeError:
        return 0

    tool_name = str(event.get("tool_name", ""))
    tool_input = event.get("tool_input")

    if tool_name == "Bash" and isinstance(tool_input, dict):
        command = str(tool_input.get("command", ""))
        if not LOOKS_LIKE_DEVICE.search(command):
            return 0
        if not SIMLEASE_EXEC.search(command) and FLUTTER_ON_SIMULATOR.search(command):
            emit("deny", FLUTTER_REASON)
            return 0
        # Hide read-only simctl calls from the upstream guard, which blocks every simctl.
        stripped = READ_ONLY_SIMCTL.sub("simctl-read-only", command)
        event = {**event, "tool_input": {**tool_input, "command": stripped}}
    elif not SIMULATOR_TOOL.search(tool_name):
        # Anything else that reaches this hook (TaskStop does) names no
        # simulator, and the upstream guard would deny it for that.
        return 0
    elif isinstance(tool_input, dict):
        # Claude's own iOS Simulator tool names the device as `device`/`udid`;
        # the upstream guard looks for `udid`-style keys.
        device = tool_input.get("device")
        if isinstance(device, str) and re.fullmatch(SIM_UDID, device) and "udid" not in tool_input:
            event = {**event, "tool_input": {**tool_input, "udid": device}}

    upstream = next((p for p in UPSTREAM_CANDIDATES if os.path.isfile(p)), None)
    if upstream is None:
        print(json.dumps({"systemMessage": "SimLease guard not found; Simulator lease NOT enforced."}))
        return 0
    result = subprocess.run([sys.executable, upstream], input=json.dumps(event), text=True,
                            capture_output=True, timeout=4)
    if result.stdout.strip():
        sys.stdout.write(result.stdout)
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
