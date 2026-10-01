#!/bin/bash
#
# Keeps the Claude Usage Visualizer signed in automatically.
#
# Runs as a Claude Code SessionStart hook. It reads Claude Code's own OAuth
# token from the login keychain and writes it to the widget's credential file.
# The widget then adopts it on its next poll and, because the token file is
# mirrored to the shared iCloud key-value store, the iPhone app picks it up too.
# So every time you start / log in to Claude Code, both apps stay up to date
# with no password prompt from the widget itself.
#
# macOS asks you to allow keychain access the FIRST time this runs. Click
# "Always Allow" once and it runs silently from then on.
#
# Best-effort and non-fatal: if the keychain read is denied or Claude Code is
# not signed in, it exits 0 without touching anything, so it can never block a
# Claude Code session from starting.
#
# Security: the token is read into a shell variable and passed to the writer on
# stdin (never as a command-line argument, which would be visible in `ps`), and
# is written to a 0600 file. It is never printed.

set -euo pipefail

BLOB="$(security find-generic-password -w -s "Claude Code-credentials" -a "$(whoami)" 2>/dev/null)" || exit 0
[ -z "${BLOB}" ] && exit 0

DIR="${HOME}/Library/Application Support/ClaudeUsageVisualizer"
mkdir -p "${DIR}"

printf '%s' "${BLOB}" | /usr/bin/python3 - "${DIR}/credentials.json" <<'PY' || exit 0
import json, os, sys, time

out = sys.argv[1]
try:
    oauth = (json.load(sys.stdin) or {}).get("claudeAiOauth") or {}
except Exception:
    sys.exit(0)

access = oauth.get("accessToken")
if not access:
    sys.exit(0)

# Claude Code stores expiresAt in milliseconds; the widget's store decodes
# dates as seconds-since-1970, so convert and stamp updatedAt in seconds too.
exp_ms = oauth.get("expiresAt")
expires = (exp_ms / 1000.0) if isinstance(exp_ms, (int, float)) else None

envelope = {
    "accessToken": access,
    "refreshToken": oauth.get("refreshToken"),
    "expiresAt": expires,
    "updatedAt": time.time(),
}

tmp = out + ".tmp"
with open(tmp, "w") as f:
    json.dump(envelope, f)
os.chmod(tmp, 0o600)
os.replace(tmp, out)
PY

exit 0
