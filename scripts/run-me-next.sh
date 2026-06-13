#!/usr/bin/env bash
# Verify the BW_SESSION-vs-backend-session fix.
#
# Bug: `collectRules` in vault.nim was re-reading BW_SESSION from env
# instead of using the session token the backend was constructed with.
# So when cmdDaemon did a fresh `bw unlock`, captured the token, passed
# it to newBwBackend(token) -- but never `putEnv`ed it -- collectRules
# called `getEnv("BW_SESSION")` -> "" -> `bw list items` with no session
# -> "Vault is locked."
#
# Fix: store session on VaultBackend; collectRules uses b.session.
#
# This script reproduces the failure path: ensure BW_SESSION is NOT in
# env, ensure no cached session exists, then start the daemon. With the
# fix, the daemon should prompt (foreground) for unlock and successfully
# load the vault.

set -u
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
DLOG=/tmp/vw-autofill-daemon.log

echo "=== build ==="
( cd "$ROOT" && nimble --legacy build 2>&1 ) | tail -5
if [ ! -x "$ROOT/bin/vw_autofill" ]; then
    echo "build FAILED"
    exit 1
fi

echo
echo "=== clear stale state ==="
pkill -9 -f vw_autofill 2>/dev/null || true
sleep 0.3
unset BW_SESSION
rm -f "$HOME/.config/vw-autofill/session"
: > "$DLOG"
echo "BW_SESSION unset, cached session removed, daemon log truncated."

echo
echo "=== start daemon (foreground) ==="
echo "It will prompt for your master password via bw unlock --raw."
echo "Expected: after unlock, daemon logs 'vault: using fresh unlock' and stays running."
echo "Press Ctrl-C to stop once you see the daemon is up."
echo
exec "$ROOT/bin/vw_autofill" daemon
