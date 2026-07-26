#!/usr/bin/env python3
"""Codex PreToolUse guard for Simulator operations."""

from __future__ import annotations

import json
import os
import re
import sys
from pathlib import Path
from typing import Any


SHELL_SIMULATOR_PATTERN = re.compile(
    r"(?:\bxcrun\s+simctl\b|\bxcodebuild\b[^\n]*(?:iphonesimulator|platform\s*=\s*iOS\s+Simulator|"
    r"-destination\s+[^\n]*\bid\s*=)|\bserve-sim\b|\bopen\s+(?:-[^\s]+\s+)*-a\s+Simulator\b)",
    re.IGNORECASE,
)
SIMLEASE_EXEC_PATTERN = re.compile(r"(?:^|[\s/'\"])(?:simlease|scripts/simlease)\s+exec\s+--token\b")
READ_ONLY_MCP_PATTERN = re.compile(r"(?:list|status|available|devices|doctor|diagnostic)", re.IGNORECASE)
SIMULATOR_ID_KEYS = {"simulatorid", "simulator_id", "udid", "deviceid", "device_id"}


def deny(reason: str) -> None:
    print(
        json.dumps(
            {
                "systemMessage": reason,
                "hookSpecificOutput": {
                    "hookEventName": "PreToolUse",
                    "permissionDecision": "deny",
                    "permissionDecisionReason": reason,
                },
            }
        )
    )


def shell_command(tool_input: Any) -> str:
    if isinstance(tool_input, str):
        return tool_input
    if not isinstance(tool_input, dict):
        return ""
    for key in ("command", "cmd"):
        value = tool_input.get(key)
        if isinstance(value, str):
            return value
    return ""


def simulator_ids(value: Any) -> set[str]:
    found: set[str] = set()
    if isinstance(value, dict):
        for key, child in value.items():
            if key.lower() in SIMULATOR_ID_KEYS and isinstance(child, str) and child:
                found.add(child)
            found.update(simulator_ids(child))
    elif isinstance(value, list):
        for child in value:
            found.update(simulator_ids(child))
    return found


def workspace_contains(workspace: str, cwd: str) -> bool:
    try:
        Path(cwd).resolve().relative_to(Path(workspace).resolve())
        return True
    except (OSError, ValueError):
        return False


def has_workspace_lease(udid: str, cwd: str) -> bool:
    lease_root = Path(os.environ.get("SIMLEASE_DIR", Path(os.environ.get("TMPDIR", "/tmp")) / "simlease"))
    metadata = lease_root / "leases" / f"{udid}.json"
    try:
        lease = json.loads(metadata.read_text())
        guard_pid = int(lease.get("guardPid", 0))
        os.kill(guard_pid, 0)
    except (OSError, ValueError, TypeError, json.JSONDecodeError):
        return False
    workspace = lease.get("workspace")
    return isinstance(workspace, str) and workspace_contains(workspace, cwd)


def main() -> int:
    try:
        event = json.load(sys.stdin)
    except json.JSONDecodeError:
        return 0

    tool_name = str(event.get("tool_name", ""))
    tool_input = event.get("tool_input")
    cwd = str(event.get("cwd", os.getcwd()))

    if tool_name == "Bash":
        command = shell_command(tool_input)
        if not SHELL_SIMULATOR_PATTERN.search(command):
            return 0
        if SIMLEASE_EXEC_PATTERN.search(command):
            return 0
        deny(
            "SimLease blocked a direct Simulator command. Acquire a lease, then run the command "
            "through `simlease exec --token <token> -- ...`."
        )
        return 0

    if READ_ONLY_MCP_PATTERN.search(tool_name):
        return 0

    ids = simulator_ids(tool_input)
    if not ids:
        deny(
            "SimLease blocked this Simulator tool call because it does not name a leased "
            "simulatorId. Acquire a lease and pass its exact UDID."
        )
        return 0
    if not any(has_workspace_lease(udid, cwd) for udid in ids):
        deny(
            "SimLease blocked this Simulator tool call because its simulatorId is not actively "
            "leased by this workspace. Acquire a lease and use the returned UDID."
        )
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
