#!/usr/bin/env python3
"""The Claude Code wrapper passes device commands to the repo's guard and adds its own rules."""
import json
import os
import subprocess
import tempfile
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
WRAPPER = ROOT / "plugins" / "simlease" / "hooks" / "claude_guard.py"
GUARD = ROOT / "plugins" / "simlease" / "hooks" / "simlease_guard.py"
SIM = "11111111-1111-1111-1111-111111111111"


def denied(tool_name: str, tool_input: dict, lease_root: str) -> bool:
    event = {"hook_event_name": "PreToolUse", "cwd": lease_root, "tool_name": tool_name, "tool_input": tool_input}
    environment = os.environ | {"SIMLEASE_GUARD_PATH": str(GUARD), "SIMLEASE_DIR": lease_root}
    result = subprocess.run(["python3", str(WRAPPER)], input=json.dumps(event), text=True,
                            capture_output=True, check=True, env=environment)
    return '"deny"' in result.stdout


def main() -> None:
    with tempfile.TemporaryDirectory(prefix="simlease-claude-hook.") as lease_root:
        def bash(command: str) -> bool:
            return denied("Bash", {"command": command}, lease_root)

        assert bash(f"flutter run -d {SIM}")
        assert not bash(f"simlease exec --token-file t -- flutter run -d {SIM}")
        assert not bash("xcrun simctl list devices booted")
        assert bash("adb -s emulator-5560 shell getprop")
        assert not bash("simlease exec --token-file t -- adb shell getprop")
        assert bash("simlease exec --token-file t -- xcrun simctl shutdown all")
        assert bash("simlease exec --token-file t -- simslim on $SIMULATOR_UDID")
        for command in ("simslim watch", f"simslim --boot-timeout 15m on {SIM}", f"simslim repair-clone {SIM} B",
                        f"SimSlim on {SIM}", f"$(which simslim) on {SIM}", f"sudo simslim off {SIM}"):
            assert bash(command), command
        for command in ("simslim list", "simslim doctor --list", f"simslim doctor {SIM} --requires push --json",
                        "simslim top --json", "simslim version", "xcrun simctl list devices -j",
                        'grep -rn "xcrun simctl" .', "rg booted docs/"):
            assert not bash(command), command
        assert bash(f'grep -rn "xcrun simctl" . ; xcrun simctl boot {SIM}')
        assert bash("killall Simulator")
        assert not bash("git status")
        assert not denied("TaskStop", {"task_id": "x"}, lease_root)
    print("Claude hook tests passed")


if __name__ == "__main__":
    main()
