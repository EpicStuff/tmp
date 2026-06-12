#!/usr/bin/env bash
# Wrapper for binding to a KDE Custom Shortcut.
#
# In System Settings -> Shortcuts -> Custom Shortcuts, create a new
# Global Shortcut -> Command/URL action, set the trigger keybind, and
# set the action to the absolute path of this script (no args needed).
#
# Why a wrapper instead of pointing directly at bin/vw_autofill:
#   - logs every invocation, so we can tell *whether* the shortcut
#     is even firing
#   - prefixes errors with a marker, so /tmp/vw-fill-shortcut.log
#     shows the exit code and any stderr
#   - lets us keep the wiring even if we change the binary path
#
# When the shortcut works but typing doesn't, check the log; when
# the log stays empty, the shortcut itself isn't firing (most often
# a KDE keybind conflict or the action not being saved).

set -u
LOG=/tmp/vw-fill-shortcut.log
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
BIN="$ROOT/bin/vw_autofill"

{
    echo "--- $(date '+%Y-%m-%d %H:%M:%S') ---"
    echo "ROOT=$ROOT"
    echo "PATH=$PATH"
    echo "DBUS_SESSION_BUS_ADDRESS=${DBUS_SESSION_BUS_ADDRESS:-unset}"
    if [ ! -x "$BIN" ]; then
        echo "ERROR: $BIN missing or not executable"
        exit 1
    fi
    "$BIN" fill
    rc=$?
    echo "exit: $rc"
    exit $rc
} >>"$LOG" 2>&1
