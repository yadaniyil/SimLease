# Security policy

## Supported versions

Security fixes are provided for the latest released version of SimLease.

## Reporting a vulnerability

Do not open a public issue for a vulnerability that could expose lease tokens, execute unintended commands, or interfere with another user's simulator session. Report it privately through the [GitHub security advisory page](https://github.com/yadaniyil/SimLease/security/advisories/new).

Include the affected version, macOS and Xcode versions, reproduction steps, and impact. Please allow a reasonable remediation window before public disclosure.

## Security model

Lease tokens authorize renewal and release. Treat them as temporary secrets and do not commit them, place them in project files, or expose them to unrelated processes. Runtime state is stored in a user-private temporary directory by default.

SimLease coordinates cooperating processes. It is not a sandbox and cannot prevent software from bypassing it and invoking Simulator or Xcode tooling directly.
