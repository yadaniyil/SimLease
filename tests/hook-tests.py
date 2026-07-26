#!/usr/bin/env python3
import json
import os
import subprocess
import tempfile
from pathlib import Path


ROOT = Path(__file__).resolve().parent.parent
HOOK = ROOT / "plugins" / "simlease" / "hooks" / "simlease_guard.py"
UDID = "11111111-1111-1111-1111-111111111111"


def invoke(tool_name: str, tool_input: object, cwd: Path, lease_root: Path) -> dict:
    event = {
        "hook_event_name": "PreToolUse",
        "session_id": "test-session",
        "turn_id": "test-turn",
        "transcript_path": None,
        "cwd": str(cwd),
        "model": "test",
        "permission_mode": "default",
        "tool_name": tool_name,
        "tool_input": tool_input,
        "tool_use_id": "test-tool",
    }
    environment = os.environ | {"SIMLEASE_DIR": str(lease_root)}
    result = subprocess.run(
        [str(HOOK)],
        input=json.dumps(event),
        text=True,
        capture_output=True,
        check=True,
        env=environment,
    )
    return json.loads(result.stdout) if result.stdout else {}


def is_denied(result: dict) -> bool:
    return result.get("hookSpecificOutput", {}).get("permissionDecision") == "deny"


def main() -> None:
    with tempfile.TemporaryDirectory(prefix="simlease-hook-tests.") as directory:
        lease_root = Path(directory)
        workspace = lease_root / "workspace"
        workspace.mkdir()

        assert not invoke("Bash", {"command": "git status"}, workspace, lease_root)
        assert is_denied(invoke("Bash", {"command": "xcrun simctl shutdown all"}, workspace, lease_root))
        assert not invoke(
            "Bash",
            {"command": "./scripts/simlease exec --token secret -- xcrun simctl launch app"},
            workspace,
            lease_root,
        )
        assert not invoke("mcp__xcodebuildmcp__list_sims", {}, workspace, lease_root)
        assert is_denied(invoke("mcp__xcodebuildmcp__build_sim", {}, workspace, lease_root))
        assert is_denied(
            invoke("mcp__xcodebuildmcp__build_sim", {"simulatorId": UDID}, workspace, lease_root)
        )

        leases = lease_root / "leases"
        leases.mkdir()
        (leases / f"{UDID}.json").write_text(
            json.dumps({"udid": UDID, "workspace": str(workspace), "guardPid": os.getpid()})
        )
        assert not invoke(
            "mcp__xcodebuildmcp__build_sim", {"simulatorId": UDID}, workspace / "Sources", lease_root
        )

    print("Codex hook tests passed")


if __name__ == "__main__":
    main()
