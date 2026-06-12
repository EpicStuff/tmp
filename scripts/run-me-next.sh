#!/usr/bin/env bash
# This script never invokes sudo. When elevation is needed it
# prints the command for you to run in another terminal (or
# the same one after answering the prompt), then waits.
#
# Iteration goal:
#   1. capture xdg-desktop-portal-kde's own log line at the
#      moment the screencast probe gets denied, in case
#      fixing portal is cheap;
#   2. install ydotool and prove keystroke injection works.

set -u
OUT=/tmp/vw-run-next.log
: > "$OUT"

pause() {
    printf '\n>>> %s\n' "$*"
    printf '>>> Press Enter when done. <<< '
    read -r _
}

echo '=== part 1: portal denial log capture (no elevation needed) ===' | tee -a "$OUT"

journalctl --user --since 'now' -f \
    -u 'plasma-xdg-desktop-portal*' \
    _COMM=xdg-desktop-portal_kde \
    _COMM=xdg-desktop-portal \
    > /tmp/vw-portal-journal.log 2>&1 &
JOURNAL_PID=$!
sleep 1

if [ ! -f /tmp/vw-recon-screencast.py ]; then
    echo '(staging /tmp/vw-recon-screencast.py via recon2.sh)'
    bash scripts/recon2.sh > /dev/null 2>&1
fi
if [ -f /tmp/vw-recon-screencast.py ]; then
    echo '$ python3 /tmp/vw-recon-screencast.py' | tee -a "$OUT"
    python3 /tmp/vw-recon-screencast.py 2>&1 | tee -a "$OUT" || true
else
    echo 'could not stage screencast probe; skipping' | tee -a "$OUT"
fi

sleep 2
kill $JOURNAL_PID 2>/dev/null || true
wait $JOURNAL_PID 2>/dev/null || true

echo | tee -a "$OUT"
echo '--- portal-kde journal during the probe ---' | tee -a "$OUT"
cat /tmp/vw-portal-journal.log | tee -a "$OUT"
echo | tee -a "$OUT"

echo '=== part 2: install ydotool ==='

if command -v ydotool >/dev/null 2>&1 && command -v ydotoold >/dev/null 2>&1; then
    echo 'ydotool already installed.' | tee -a "$OUT"
else
    cat <<'INSTRUCTIONS'

Open another terminal (or use this one) and run:

    sudo pacman -S --noconfirm ydotool

INSTRUCTIONS
    pause 'after the install finishes'
fi
echo '$ which ydotool ydotoold' | tee -a "$OUT"
which ydotool ydotoold 2>&1 | tee -a "$OUT"

echo
echo '=== part 3: start ydotoold (needs root) ==='
SOCK=/tmp/.ydotool_socket
cat <<INSTRUCTIONS

Run this in another terminal and leave it running:

    sudo ydotoold --socket-path=$SOCK --socket-perm=0666

(it stays attached to the terminal printing nothing; you can
suspend it with Ctrl-Z then 'bg' if you prefer, or run with &.)

We use a custom socket with 0666 perms so the ydotool *client*
(next step) doesn't itself need sudo.

INSTRUCTIONS
pause 'after ydotoold is running'

if ! pgrep -x ydotoold >/dev/null; then
    echo 'WARNING: ydotoold does not appear to be running. Continuing anyway' | tee -a "$OUT"
    echo 'but the smoke test will probably fail.' | tee -a "$OUT"
fi
echo '$ pgrep -af ydotoold' | tee -a "$OUT"
pgrep -af ydotoold | tee -a "$OUT" || echo '(none)' | tee -a "$OUT"

echo
echo '=== part 4: smoke test (no elevation; script runs this) ==='
echo
echo '>>> Now focus a window where text is safe to receive — a scratch'
echo '>>> text editor, an empty terminal, the URL bar of about:blank, etc.'
echo '>>> Press Enter here when focused; typing fires 3 seconds later.'
read -r _
( sleep 3; YDOTOOL_SOCKET=$SOCK ydotool type 'hello from ydotool' ) &
TYPE_PID=$!
wait $TYPE_PID
echo
printf 'Did "hello from ydotool" appear in your target window? (y/n) '
read -r ANSWER
echo "user answer: $ANSWER" | tee -a "$OUT"

echo
echo '=== cleanup ==='
cat <<INSTRUCTIONS

Back in the terminal where ydotoold is running, Ctrl-C to stop it
(or run 'sudo pkill -x ydotoold' in any terminal).

INSTRUCTIONS

echo
echo "log file: $OUT"
echo
echo 'Paste back:'
echo '  - /tmp/vw-run-next.log'
echo '  - whether the ydotool smoke test typed into your target window'
