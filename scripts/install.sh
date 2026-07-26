#!/usr/bin/env bash
set -euo pipefail

PROJECT_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SOURCE_CLI="${PROJECT_ROOT}/plugins/simlease/skills/simlease/scripts/simlease"
PREFLIGHT="${PROJECT_ROOT}/plugins/simlease/skills/simlease/scripts/preflight"
INSTALL_PREFIX="${SIMLEASE_INSTALL_PREFIX:-${HOME}/.local}"

usage() {
    cat <<'EOF'
Usage: ./scripts/install.sh [--prefix DIRECTORY]

Installs simlease into DIRECTORY/bin. The default prefix is ~/.local.
SIMLEASE_INSTALL_PREFIX may also set the prefix.
EOF
}

while [[ $# -gt 0 ]]; do
    case "$1" in
        --prefix)
            [[ $# -ge 2 ]] || { printf '%s\n' '--prefix requires a directory' >&2; exit 1; }
            INSTALL_PREFIX="$2"
            shift 2
            ;;
        -h|--help)
            usage
            exit 0
            ;;
        *)
            printf 'unknown option: %s\n' "$1" >&2
            usage >&2
            exit 1
            ;;
    esac
done

"$PREFLIGHT"
install -d "${INSTALL_PREFIX}/bin"
install -m 0755 "$SOURCE_CLI" "${INSTALL_PREFIX}/bin/simlease"

printf 'Installed SimLease at %s\n' "${INSTALL_PREFIX}/bin/simlease"
case ":${PATH}:" in
    *":${INSTALL_PREFIX}/bin:"*) ;;
    *) printf 'Add %s/bin to PATH before invoking simlease by name.\n' "$INSTALL_PREFIX" ;;
esac
