#!/usr/bin/env bash
# Start the vw-autofill daemon with a single command.
# Prompts you for your master password via `bw unlock --raw`, sets
# the standard env vars, and execs the daemon.
#
# This script never runs sudo. If ydotoold isn't already running it
# prints the sudo command for you to run in another terminal and
# exits, so this terminal stays free for the daemon itself.
#
# Override defaults by exporting before invoking:
#   YDOTOOL_SOCKET=/some/other/sock ./scripts/start-daemon.sh
#   VW_AUTOFILL_LOG=/path/to/log    ./scripts/start-daemon.sh

set -u
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
: "${YDOTOOL_SOCKET:=/tmp/.ydotool_socket}"
: "${VW_AUTOFILL_LOG:=/tmp/vw-autofill-daemon.log}"

if ! pgrep -x ydotoold >/dev/null; then
    cat <<EOF
ydotoold not running. In another terminal, run:
    sudo ydotoold --socket-path=$YDOTOOL_SOCKET --socket-perm=0666
Leave that running, then re-run this script.
EOF
    exit 1
fi

# Reuse BW_SESSION if it's already exported in this shell (handy when
# the previous daemon was killed and you don't want to retype the
# master password). Otherwise prompt via `bw unlock --raw`.
if [ -z "${BW_SESSION:-}" ]; then
    echo "Unlocking vault..."
    BW_SESSION=$(bw unlock --raw)
fi
if [ -z "$BW_SESSION" ]; then
    echo "bw unlock returned empty session, aborting"
    exit 1
fi

exec env \
    BW_SESSION="$BW_SESSION" \
    YDOTOOL_SOCKET="$YDOTOOL_SOCKET" \
    VW_AUTOFILL_LOG="$VW_AUTOFILL_LOG" \
    "$ROOT/bin/vw_autofill" daemon
