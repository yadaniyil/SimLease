# Security policy

## Supported versions

Security fixes are provided for the latest released version of SimLease.

## Reporting a vulnerability

Do not open a public issue for a vulnerability that could expose lease tokens, execute unintended commands, or interfere with another user's Simulator or emulator session. Report it privately through the [GitHub security advisory page](https://github.com/yadaniyil/SimLease/security/advisories/new).

Include the affected version, the macOS, Xcode and Android emulator versions, reproduction steps, and impact. Please allow a reasonable remediation window before public disclosure.

## Security model

Lease tokens authorize renewal and release. Treat them as temporary secrets: do not commit them, place them in project files, or expose them to unrelated processes. `--token-file` writes a token with mode 0600. Runtime state is stored in a user-private temporary directory by default.

SimLease coordinates cooperating processes. It is not a sandbox. Its guard hooks read command text before a tool call runs. They cannot stop software that bypasses them and invokes Simulator, Xcode, emulator or `adb` tooling directly, for example from inside a script.
