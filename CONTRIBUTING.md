# Contributing to SimLease

Contributions are welcome through pull requests and issues.

## Development setup

SimLease needs macOS, the Xcode command-line tools, Bash, `jq` and `python3`. CI also runs ShellCheck (`brew install shellcheck`). Clone the repository, then run every check CI runs:

```bash
./plugins/simlease/skills/simlease/scripts/preflight
bash -n bin/simlease scripts/install.sh plugins/simlease/skills/simlease/scripts/* tests/simlease-tests.sh
shellcheck bin/simlease scripts/install.sh plugins/simlease/skills/simlease/scripts/* tests/simlease-tests.sh
./tests/plugin-tests.py
./tests/hook-tests.py
./tests/claude-hook-tests.py
./tests/simlease-tests.sh
```

The lease tests run against fake Simulators (`SIMLEASE_DEVICES`), fake emulators (`SIMLEASE_ANDROID_TEST_STATE_DIR`, `SIMLEASE_ANDROID_AVDS`) and a fake simslim (`SIMLEASE_SIMSLIM_BIN`). They use a temporary lease directory and config directory, so they never touch real devices, your leases, or your `~/.config/simlease` files.

A change to booting, slimming or stopping devices also needs one run on real devices. Lease a spare Simulator with `--device`, and an emulator with `--avd`, and describe the result in the pull request.

## Pull requests

- `plugins/simlease/skills/simlease/scripts/simlease` is the canonical implementation. `bin/simlease` is only the repository wrapper.
- `plugins/simlease/hooks/simlease_guard.py` is the guard shared by Codex and Claude Code. `plugins/simlease/hooks/claude_guard.py` is the Claude Code wrapper around it.
- Add or update tests for every behaviour change, including the hook tests for any new guard rule.
- Keep example commands copy-pasteable. Lease variables go inside single-quoted `sh -c '…'`.
- Update the manifest version and `SIMLEASE_VERSION` together, only when preparing a release.

By contributing, you agree that your contribution is licensed under the MIT License.
