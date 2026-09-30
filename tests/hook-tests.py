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
        def bash_denied(command: str) -> bool:
            return is_denied(invoke("Bash", {"command": command}, workspace, lease_root))

        # Android emulators need a lease; physical devices and read-only adb calls pass.
        for command in (
            "emulator -avd pixel_test -port 5560",
            "~/Library/Android/sdk/emulator/emulator @low_ram_test -no-window &",
            "adb -s emulator-5560 install app.apk",
            "adb -e shell getprop",
            "adb shell pm list packages",
            "flutter run -d emulator-5572 --debug",
            "ANDROID_SERIAL=emulator-5560 adb logcat -d",
        ):
            assert bash_denied(command), command
        for command in (
            "adb devices",
            "adb -s R58N12ABCDE install app.apk",
            "emulator -list-avds",
            "simlease exec --token-file lease.token -- adb shell getprop",
            "X=$(simlease exec --token abc -- adb shell getprop ro.build.version.sdk)",
            "simlease acquire --avd pixel_test --owner task-1 --token-file t --json",
        ):
            assert not bash_denied(command), command
        # Hazards to every agent's devices are blocked even inside a lease.
        for command in (
            "simlease exec --token abc -- xcrun simctl shutdown all",
            "simlease exec --token abc -- xcrun simctl io booted screenshot a.png",
            "simlease exec --token abc -- simslim on $SIMULATOR_UDID",
            "killall Simulator",
            "killall qemu-system-aarch64",
            "pkill -f qemu-system",
            "pkill -f emulator",
            "adb kill-server",
        ):
            assert bash_denied(command), command
        for command in (
            "pkill -f 'qemu-system.* -port 5560'",
            "pkill -f 'flutter_tools.snapshot run -d emulator-5560'",
        ):
            assert not bash_denied(command), command

        # simslim commands that change a device are blocked, even inside a lease,
        # however simslim is spelled or started and whatever global options come first.
        for command in (
            f"simslim on {UDID}",
            f"simslim on {UDID} --no-reboot",
            f"simslim off {UDID}",
            "simslim watch",
            "simslim --spawn-timeout 5m watch",
            f"simslim repair-clone {UDID} 22222222-2222-2222-2222-222222222222",
            f"simslim clone {UDID} Copy",
            f"simslim erase {UDID}",
            f"simslim delete {UDID}",
            f"simslim disk-clean {UDID} --categories caches --confirm",
            f"simslim shutdown {UDID}",
            f"simslim boot {UDID}",
            f"simslim rename {UDID} New",
            f"simslim --boot-timeout 15m on {UDID}",
            f"simslim --boot-timeout=15m off {UDID}",
            f"simslim --set testing on {UDID}",
            f'simslim --set "my set" on {UDID}',
            f"SimSlim on {UDID}",
            f'"simslim" on {UDID}',
            f"'simslim' on {UDID}",
            f"$(which simslim) on {UDID}",
            f"`which simslim` on {UDID}",
            f"/opt/homebrew/bin/simslim on {UDID}",
            f"env X=1 simslim on {UDID}",
            f"X=1 simslim on {UDID}",
            f"sudo simslim on {UDID}",
            f"echo {UDID} | xargs simslim on",
        ):
            assert bash_denied(command), command
        reason = invoke("Bash", {"command": "simslim watch"}, workspace, lease_root)["systemMessage"]
        assert "`simslim watch`" in reason and "other agents'" in reason and "doctor" in reason, reason
        reason = invoke("Bash", {"command": "simslim repair-clone A B"}, workspace, lease_root)["systemMessage"]
        assert "`simslim repair-clone`" in reason and "shut down" in reason, reason
        # Read-only simslim commands pass.
        for command in (
            "simslim list",
            "simslim list --json",
            "simslim list --booted",
            "simslim profiles",
            "simslim profiles store",
            f"simslim status {UDID}",
            f"simslim status {UDID} --dropped",
            f"simslim verify {UDID} --except photos,store",
            "simslim doctor --list",
            f"simslim doctor {UDID} --requires push,storekit",
            f"simslim doctor {UDID} --requires push --json",
            f"simslim measure {UDID}",
            f"simslim size {UDID}",
            "simslim top",
            "simslim top --json",
            f"simslim disk-plan {UDID}",
            "simslim disk-categories",
            "simslim version",
            "simslim --help",
            "simslim --boot-timeout 15m list",
            "simslim profile ./dev.json",
        ):
            assert not bash_denied(command), command

        # Read-only simctl needs no lease; anything else still does.
        for command in (
            "xcrun simctl list devices -j",
            "xcrun simctl list devices booted",
            "xcrun simctl list devices | grep -i booted",
            "xcrun simctl help",
        ):
            assert not bash_denied(command), command
        for command in (
            f"xcrun simctl boot {UDID}",
            f"xcrun simctl list devices -j; xcrun simctl boot {UDID}",
        ):
            assert bash_denied(command), command

        # Text searches may mention device commands; a device command next to one is still caught.
        for command in (
            'grep -rn "xcrun simctl" .',
            "rg booted docs/",
            'rg -n "xcrun simctl io booted" docs/',
            'grep -rn "simslim on" README.md',
            'git grep -n "xcrun simctl"',
            'ag "killall Simulator" .',
            'grep -rn "xcrun simctl" . | head -5',
        ):
            assert not bash_denied(command), command
        for command in (
            f'grep -rn "xcrun simctl" . ; xcrun simctl boot {UDID}',
            'grep -rn "xcrun simctl" . && simslim watch',
            f"grep foo $(xcrun simctl boot {UDID})",
            f"grep foo `simslim on {UDID}`",
            f'rg --pre "xcrun simctl boot {UDID}" foo',
            "grep -l x . | xargs simslim on",
            'grep "simlease exec --token t" . ; xcrun simctl boot X',
        ):
            assert bash_denied(command), command

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
        (leases / f"{UDID}.json").write_text(
            json.dumps(
                {
                    "udid": UDID,
                    "workspace": str(workspace),
                    "guardPid": os.getpid(),
                    "guardLabel": "com.simlease.guard.not-running",
                }
            )
        )
        assert is_denied(
            invoke(
                "mcp__xcodebuildmcp__build_sim",
                {"simulatorId": UDID},
                workspace / "Sources",
                lease_root,
            )
        )

    print("Codex hook tests passed")


if __name__ == "__main__":
    main()
