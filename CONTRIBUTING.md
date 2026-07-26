# Contributing to SimLease

Contributions are welcome through pull requests and issues.

## Development setup

SimLease requires macOS, Xcode command-line tools, Bash, and `jq`. Clone the repository, then run:

```bash
./plugins/simlease/skills/simlease/scripts/preflight
./tests/plugin-tests.py
./tests/simlease-tests.sh
```

The simulator tests use synthetic device records and an isolated temporary lease directory. They do not modify real simulators.

## Pull requests

- Keep the bundled implementation at `plugins/simlease/skills/simlease/scripts/simlease` canonical.
- Keep `bin/simlease` as the repository compatibility wrapper.
- Add or update tests for behavior changes.
- Run Bash syntax checks, ShellCheck, plugin validation, and the complete test suite.
- Update the manifest version only when preparing a release.

By contributing, you agree that your contribution is licensed under the MIT License.
