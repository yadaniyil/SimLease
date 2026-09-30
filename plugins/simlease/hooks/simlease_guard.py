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
# `xcrun simctl list` and `xcrun simctl help` read nothing but state: no lease needed.
READ_ONLY_SIMCTL_PATTERN = re.compile(r"\bxcrun\s+simctl\s+(?:list|help)\b", re.IGNORECASE)
SIMLEASE_EXEC_PATTERN = re.compile(r"(?:^|[\s/'\"(])(?:simlease|scripts/simlease)\s+exec\s+--token\b")
# Read-only text searches may name device commands in their arguments, as in
# `grep -rn "xcrun simctl" .`. The guard blanks such a search before it matches
# anything, when it is a top-level command. Commands are split on every
# separator, even inside quotes, so `$(...)` and backticks are never blanked
# with the search around them; a quoted separator only makes the guard stricter.
COMMAND_SEPARATOR = re.compile(r"(&&|\|\||[;&|\n()`])")
TEXT_SEARCH = re.compile(
    r"\s*(?:[A-Za-z_]\w*=\S*\s+)*(?:grep|egrep|fgrep|rg|ag|git\s+(?:--no-pager\s+)?grep)(?:\s|$)"
)
# Options that make a search run another program: rg --pre and --hostname-bin,
# ag --pager, git grep -O/--open-files-in-pager.
SEARCH_RUNS_A_PROGRAM = re.compile(
    r"(?:^|\s)(?:--pre\b|--hostname-bin\b|--pager\b|--open-files-in-pager\b|-[A-Za-z]*O)"
)
# simslim commands that change a device. The read-only ones pass: list,
# profiles, status, verify, doctor, measure, size, top, disk-plan,
# disk-categories, version, and profile (it only writes a local JSON file).
SIMSLIM_CHANGES = (
    "on", "off", "watch", "clone", "repair-clone", "erase", "delete", "disk-clean", "boot", "shutdown", "rename",
)
SIMSLIM_CHANGE_PATTERN = re.compile(
    # simslim by name or path, quoted, or from $(which simslim) or `which simslim`
    r"\bsimslim[\"'`)}]*"
    # global options before the command (--set testing, --boot-timeout=15m)
    r"(?:\s+-{1,2}\w[\w-]*(?:=[^\s;&|()]*|\s+(?:\"[^\"]*\"|'[^']*'|[^\s;&|()\"'-][^\s;&|()]*))?)*"
    r"\s+[\"']?(" + "|".join(SIMSLIM_CHANGES) + r")(?![\w-])",
    re.IGNORECASE,
)
SIMSLIM_PROFILE_REASON = (
    "slimming persists on the device, and SimLease keeps every leased Simulator on one shared "
    "profile. Need more services? `simlease acquire --keep-services <categories> ...`."
)
SIMSLIM_REASONS = {
    "on": SIMSLIM_PROFILE_REASON,
    "off": SIMSLIM_PROFILE_REASON,
    "watch": "it slims every Simulator as it boots, including pinned ones and other agents' leased "
    "ones, and runs until Ctrl-C.",
    "repair-clone": "it can keep another agent's source Simulator shut down.",
}
SIMSLIM_OTHER_REASON = (
    "it changes, boots or stops a Simulator another agent may hold. SimLease boots, slims and "
    "shuts down leased Simulators itself."
)
SIMSLIM_READ_ONLY_HINT = (
    "Read-only simslim commands are fine: list, profiles, status, verify, doctor, measure, size, "
    "top --json, disk-plan. To check features, run "
    "`simslim doctor \"$SIMULATOR_UDID\" --requires <features>` inside `simlease exec`."
)
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
        SIMSLIM_CHANGE_PATTERN,
        lambda match: simslim_reason(match.group(1).lower()),
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


def simslim_reason(command: str) -> str:
    reason = SIMSLIM_REASONS.get(command, SIMSLIM_OTHER_REASON)
    return f"SimLease blocked `simslim {command}`: {reason} {SIMSLIM_READ_ONLY_HINT}"


def is_text_search(segment: str) -> bool:
    return bool(TEXT_SEARCH.match(segment)) and not SEARCH_RUNS_A_PROGRAM.search(segment)


def blank_text_searches(command: str) -> str:
    """Blanks top-level grep, rg, ag and git grep commands, keeping every separator."""
    parts = COMMAND_SEPARATOR.split(command)
    depth = 0
    in_backticks = False
    for index, part in enumerate(parts):
        if index % 2:
            if part == "(":
                depth += 1
            elif part == ")":
                depth = max(0, depth - 1)
            elif part == "`":
                in_backticks = not in_backticks
        elif depth == 0 and not in_backticks and is_text_search(part):
            parts[index] = " " * len(part)
    return "".join(parts)


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
        command = blank_text_searches(READ_ONLY_SIMCTL_PATTERN.sub("simctl-read-only", command))
        for pattern, reason in SHARED_DEVICE_HAZARDS:
            match = pattern.search(command)
            if match:
                deny(reason(match) if callable(reason) else reason)
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
