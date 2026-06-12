#!/usr/bin/env bash
# Sanity check that the typing layer is set up correctly.
# Uses the hard-coded ydotool device id (2333:6666) - we
# already discovered it once, no need to re-detect.
#
# This script never invokes sudo. When elevation is needed
# it prints the command for you to run yourself.

set -u
OUT=/tmp/vw-run-next.log
: > "$OUT"
YDOTOOL_ID="2333:6666"
SOCK=/tmp/.ydotool_socket

pause() {
    printf '\n>>> %s\n' "$*"
    printf '>>> Press Enter when done. <<< '
    read -r _
}

echo "=== checking ydotool setup ===" | tee -a "$OUT"
echo "expected device id: $YDOTOOL_ID" | tee -a "$OUT"
echo

# 1. ydotool binaries present?
if command -v ydotool >/dev/null 2>&1 && command -v ydotoold >/dev/null 2>&1; then
    echo "ydotool binaries: OK" | tee -a "$OUT"
else
    echo "ydotool binaries: MISSING" | tee -a "$OUT"
    cat <<INSTRUCTIONS
Install with:
    sudo pacman -S --noconfirm ydotool
INSTRUCTIONS
    pause 'after install'
fi

# 2. keyd ignoring ydotool?
if command -v keyd >/dev/null 2>&1; then
    echo | tee -a "$OUT"
    echo "checking keyd journal for ydotool ignore line..." | tee -a "$OUT"
    if journalctl -u keyd --no-pager 2>/dev/null | grep -F "$YDOTOOL_ID" | grep -qi 'ignor'; then
        echo "keyd is ignoring ydotool: OK" | tee -a "$OUT"
    else
        echo "keyd is NOT ignoring ydotool" | tee -a "$OUT"
        cat <<INSTRUCTIONS
Edit /etc/keyd/default.conf and add this under [ids]:
    -$YDOTOOL_ID
Then:
    sudo systemctl restart keyd
INSTRUCTIONS
        pause 'after editing keyd config and restarting'
    fi
fi

# 3. ydotoold running?
if pgrep -x ydotoold >/dev/null; then
    echo "ydotoold running: OK" | tee -a "$OUT"
else
    cat <<INSTRUCTIONS

In another terminal, run:
    sudo ydotoold --socket-path=$SOCK --socket-perm=0666
Leave it running.
INSTRUCTIONS
    pause 'after starting ydotoold'
fi

# 4. typing smoke test
echo | tee -a "$OUT"
echo ">>> Focus a safe target window (scratch editor / about:blank URL bar)."
echo ">>> Press Enter; typing fires in 3 seconds."
read -r _
( sleep 3; YDOTOOL_SOCKET=$SOCK ydotool type 'hello world 123 !@#$%' ) &
wait $!
echo
printf 'Did "hello world 123 !@#%%" appear cleanly? (y/n/partial) '
read -r ANSWER
echo "user answer: $ANSWER" | tee -a "$OUT"

echo
echo "log: $OUT"
echo
echo 'Paste back:'
echo "  - /tmp/vw-run-next.log"
echo "  - the answer above (typed cleanly?)"
