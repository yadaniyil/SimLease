#!/usr/bin/env bash
set -euo pipefail

PROJECT_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SOURCE_CLI="${PROJECT_ROOT}/plugins/simlease/skills/simlease/scripts/simlease"
PREFLIGHT="${PROJECT_ROOT}/plugins/simlease/skills/simlease/scripts/preflight"
INSTALL_PREFIX="${SIMLEASE_INSTALL_PREFIX:-${HOME}/.local}"
HOOKS_SOURCE="${PROJECT_ROOT}/plugins/simlease/hooks"
CONFIG_DIR="${SIMLEASE_CONFIG_DIR:-${XDG_CONFIG_HOME:-${HOME}/.config}/simlease}"
WITH_CLAUDE_HOOK=false

usage() {
    cat <<'EOF'
Usage: ./scripts/install.sh [--prefix DIRECTORY] [--with-claude-hook]

Installs simlease into DIRECTORY/bin and its guard hook into
DIRECTORY/share/simlease/hooks. The default prefix is ~/.local.
SIMLEASE_INSTALL_PREFIX may also set the prefix.

Creates ~/.config/simlease/simslim-profile.json (the shared simslim profile)
and ~/.config/simlease/pinned when they do not exist yet; never overwrites them.

--with-claude-hook also installs the Claude Code guard as
~/.claude/hooks/simlease_guard_claude.py (register it as a PreToolUse hook).
EOF
}

while [[ $# -gt 0 ]]; do
    case "$1" in
        --prefix)
            [[ $# -ge 2 ]] || { printf '%s\n' '--prefix requires a directory' >&2; exit 1; }
            INSTALL_PREFIX="$2"
            shift 2
            ;;
        --with-claude-hook)
            WITH_CLAUDE_HOOK=true
            shift
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
install -d "${INSTALL_PREFIX}/share/simlease/hooks"
install -m 0755 "${HOOKS_SOURCE}/simlease_guard.py" "${INSTALL_PREFIX}/share/simlease/hooks/simlease_guard.py"

install -d -m 0700 "$CONFIG_DIR"
if [[ ! -f "${CONFIG_DIR}/simslim-profile.json" ]]; then
    # Categories every project's app needs on any Simulator: photo library,
    # StoreKit and push, Apple sign-in and keychain, universal links and web
    # sign-in. A lease adds more with --keep-services.
    printf '%s\n' '{"name":"shared","except":["photos","store","icloud","web"],"keep":[]}' \
        > "${CONFIG_DIR}/simslim-profile.json"
    printf 'Created %s\n' "${CONFIG_DIR}/simslim-profile.json"
fi
if [[ ! -f "${CONFIG_DIR}/pinned" ]]; then
    printf '%s\n' '# Simulator UDIDs automatic simlease picks skip (signed in, seeded media).' \
        '# One per line; simlease acquire --device <UDID> still leases them.' > "${CONFIG_DIR}/pinned"
    printf 'Created %s\n' "${CONFIG_DIR}/pinned"
fi

if [[ "$WITH_CLAUDE_HOOK" == "true" ]]; then
    install -d "${HOME}/.claude/hooks"
    install -m 0755 "${HOOKS_SOURCE}/claude_guard.py" "${HOME}/.claude/hooks/simlease_guard_claude.py"
    printf 'Installed the Claude Code guard at %s\n' "${HOME}/.claude/hooks/simlease_guard_claude.py"
fi

printf 'Installed SimLease at %s\n' "${INSTALL_PREFIX}/bin/simlease"
case ":${PATH}:" in
    *":${INSTALL_PREFIX}/bin:"*) ;;
    *) printf 'Add %s/bin to PATH before invoking simlease by name.\n' "$INSTALL_PREFIX" ;;
esac
