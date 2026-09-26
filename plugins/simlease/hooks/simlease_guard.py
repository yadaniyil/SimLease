#!/usr/bin/env python3
"""Codex PreToolUse guard for Simulator operations."""

from __future__ import annotations

import json
import os
import re
import subprocess
import sys
from pathlib import Path
from typing import Any


SHELL_SIMULATOR_PATTERN = re.compile(
    r"(?:\bxcrun\s+simctl\b|\bxcodebuild\b[^\n]*(?:iphonesimulator|platform\s*=\s*iOS\s+Simulator|"
    r"-destination\s+[^\n]*\bid\s*=)|\bserve-sim\b|\bopen\s+(?:-[^\s]+\s+)*-a\s+Simulator\b)",
    re.IGNORECASE,
)
SIMLEASE_EXEC_PATTERN = re.compile(r"(?:^|[\s/'\"(])(?:simlease|scripts/simlease)\s+exec\s+--token\b")
# Android: booting an emulator, adb aimed at an emulator, and adb device
# commands with no target (they hit whichever device answers, often another
# agent's). Physical devices named with `adb -s <serial>` pass.
ANDROID_DEVICE_PATTERN = re.compile(
    r"(?:(?:^|[\s;&|(/'\"])emulator\s+(?:-avd\b|@)"
    r"|\badb\b[^\n;&|]*?(?:-s\s+['\"]?emulator-\d+|\s-e\b)"
    r"|\bflutter\s+(?:run|drive|install|test|attach)\b[^\n;&|]*?-d\s+['\"]?emulator-\d+"
    r"|\badb\s+(?:shell|install|install-multiple|uninstall|push|pull|logcat|emu|reboot|root|unroot"
    r"|exec-out|exec-in|forward|reverse|wait-for-device|bugreport|remount)\b)"
)
# Commands that break devices other agents hold, even from inside a lease.
SHARED_DEVICE_HAZARDS = (
    (
        re.compile(r"\bsimctl\s+(?:shutdown|erase|delete)\s+all\b"),
        "SimLease blocked `simctl ... all`: it hits every agent's Simulator. Name your leased UDID.",
    ),
    (
        re.compile(r"\bsimctl\s+(?!list\b|help\b)[\w-]+\b[^\n;&|]*\bbooted\b"),
        "SimLease blocked `simctl ... booted`: with several Simulators booted it picks any of them. "
        "Use the leased UDID (`$SIMULATOR_UDID` inside `simlease exec`).",
    ),
    (
        re.compile(r"\bsimslim\s+(?:on|off|erase|delete|disk-clean|shutdown|boot|clone|rename)\b"),
        "SimLease blocked a simslim change: simlease slims every leased Simulator with one shared "
        "profile. Need more services? `simlease acquire --keep-services <categories> ...`.",
    ),
    (
        re.compile(r"\bkillall\b[^\n;&|]*\b(?:Simulator|qemu[\w-]*|emulator)\b"),
        "SimLease blocked `killall`: it stops every agent's Simulators or emulators. "
        "Release your lease instead (`simlease release`).",
    ),
    (
        re.compile(r"\bpkill\b(?![^\n;&|]*(?:-port\s+\d+|emulator-\d+|[0-9A-F]{8}-[0-9A-F]{4}))"
                   r"[^\n;&|]*\b(?:Simulator|CoreSimulator|qemu[\w-]*|emulator)\b"),
        "SimLease blocked a `pkill` that matches every Simulator or emulator. Name your own "
        "port or serial, or release your lease instead.",
    ),
    (
        re.compile(r"\badb\b[^\n;&|]*\bkill-server\b"),
        "SimLease blocked `adb kill-server`: it cuts every agent's device connection.",
    ),
)
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
    except (OSError, ValueError, TypeError, json.JSONDecodeError):
        return False
    guard_label = lease.get("guardLabel")
    if isinstance(guard_label, str) and guard_label:
        try:
            job = subprocess.run(
                ["launchctl", "list", guard_label],
                text=True,
                capture_output=True,
                check=False,
            )
        except OSError:
            return False
        if job.returncode != 0 or not re.search(r'"PID"\s*=\s*\d+;', job.stdout):
            return False
    else:
        try:
            guard_pid = int(lease.get("guardPid", 0))
            os.kill(guard_pid, 0)
        except (OSError, ValueError, TypeError):
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
        for pattern, reason in SHARED_DEVICE_HAZARDS:
            if pattern.search(command):
                deny(reason)
                return 0
        is_simulator = bool(SHELL_SIMULATOR_PATTERN.search(command))
        if not is_simulator and not ANDROID_DEVICE_PATTERN.search(command):
            return 0
        if SIMLEASE_EXEC_PATTERN.search(command):
            return 0
        if is_simulator:
            deny(
                "SimLease blocked a direct Simulator command. Acquire a lease, then run the command "
                "through `simlease exec --token <token> -- ...`."
            )
        else:
            deny(
                "SimLease blocked a direct Android emulator command. Lease an emulator: "
                "`simlease acquire --avd <AVD> --owner <task> --wait 600 --token-file <file>`, then "
                "`simlease exec --token-file <file> -- adb ...` (ANDROID_SERIAL is set). "
                "A physical device: `adb -s <its serial>`."
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
