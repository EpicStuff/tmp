#!/usr/bin/env bash
# Two parts:
#   1. One last portal probe with portal-kde's own log tailed,
#      so we see *why* it denied (in case fixing it is cheap).
#   2. Install ydotool and prove keystroke injection works.
# Result of (2) determines whether the typing layer is unblocked.

set -u

OUT=/tmp/vw-run-next.log
: > "$OUT"

echo '=== part 1: portal denial log capture ===' | tee -a "$OUT"
echo 'Tailing xdg-desktop-portal-kde journal in background, then' | tee -a "$OUT"
echo 'running the screencast probe; capturing whatever portal-kde' | tee -a "$OUT"
echo 'says at the moment of denial.' | tee -a "$OUT"
echo | tee -a "$OUT"

journalctl --user --since 'now' -f \
    -u 'plasma-xdg-desktop-portal*' \
    _COMM=xdg-desktop-portal_kde \
    _COMM=xdg-desktop-portal \
    > /tmp/vw-portal-journal.log 2>&1 &
JOURNAL_PID=$!
sleep 1

if [ -f /tmp/vw-recon-screencast.py ]; then
    echo '$ python3 /tmp/vw-recon-screencast.py' | tee -a "$OUT"
    python3 /tmp/vw-recon-screencast.py 2>&1 | tee -a "$OUT" || true
else
    echo 'vw-recon-screencast.py missing; running bash scripts/recon2.sh to stage it'
    bash scripts/recon2.sh > /dev/null 2>&1
    if [ -f /tmp/vw-recon-screencast.py ]; then
        python3 /tmp/vw-recon-screencast.py 2>&1 | tee -a "$OUT" || true
    fi
fi

sleep 2
kill $JOURNAL_PID 2>/dev/null || true
wait $JOURNAL_PID 2>/dev/null || true

echo | tee -a "$OUT"
echo '--- portal-kde journal during the probe ---' | tee -a "$OUT"
cat /tmp/vw-portal-journal.log | tee -a "$OUT"
echo | tee -a "$OUT"

echo '=== part 2: ydotool install + smoke test ===' | tee -a "$OUT"

if ! command -v ydotool >/dev/null 2>&1; then
    echo 'installing ydotool...'
    sudo pacman -S --noconfirm ydotool 2>&1 | tail -3 | tee -a "$OUT"
fi

# Locate ydotoold + udev rule so we can confirm setup is sane.
echo '$ which ydotool ydotoold' | tee -a "$OUT"
which ydotool ydotoold 2>&1 | tee -a "$OUT"
echo '$ ls /usr/lib/udev/rules.d/*ydotool* 2>/dev/null' | tee -a "$OUT"
ls /usr/lib/udev/rules.d/*ydotool* 2>/dev/null | tee -a "$OUT" || echo '(no ydotool udev rule shipped)' | tee -a "$OUT"
echo '$ systemctl --user list-unit-files | grep ydotool' | tee -a "$OUT"
systemctl --user list-unit-files 2>/dev/null | grep ydotool | tee -a "$OUT" || \
    echo '(no user ydotool unit; will run as root for the probe)' | tee -a "$OUT"

echo | tee -a "$OUT"
echo 'Smoke test now. We start ydotoold as root, you focus a target' | tee -a "$OUT"
echo 'window (anywhere safe to receive typing — a scratch text editor,' | tee -a "$OUT"
echo 'an empty terminal, the URL bar of a browser tab on about:blank).' | tee -a "$OUT"
echo 'Then we send "hello from ydotool" via ydotool.' | tee -a "$OUT"
echo | tee -a "$OUT"

# Background ydotoold as root, with a known socket path.
SOCK=/tmp/.ydotool_socket
sudo pkill -x ydotoold 2>/dev/null || true
sleep 0.3
sudo bash -c "YDOTOOL_SOCKET=$SOCK ydotoold --socket-path=$SOCK --socket-perm=0666 >/tmp/vw-ydotoold.log 2>&1 &"
sleep 1
if ! pgrep -x ydotoold >/dev/null; then
    echo 'ydotoold failed to start. log:' | tee -a "$OUT"
    sudo cat /tmp/vw-ydotoold.log | tee -a "$OUT"
    exit 1
fi
echo 'ydotoold running (pid ' "$(pgrep -x ydotoold)" ').' | tee -a "$OUT"

echo
echo '>>> NOW: focus a window where you want text typed.'
echo '>>> Press Enter here when ready. Typing happens 3 seconds later.'
read -r _
( sleep 3; YDOTOOL_SOCKET=$SOCK ydotool type 'hello from ydotool' ) &
TYPE_PID=$!
wait $TYPE_PID
echo
echo 'Did "hello from ydotool" appear in the target window? (y/n)' | tee -a "$OUT"
read -r ANSWER
echo "user answer: $ANSWER" | tee -a "$OUT"

# Clean up ydotoold.
sudo pkill -x ydotoold 2>/dev/null || true

echo | tee -a "$OUT"
echo '=== summary ==='
echo "log: $OUT"
echo
echo 'Paste back:'
echo '  - /tmp/vw-run-next.log (everything from this run, including the'
echo '    portal denial log)'
echo
echo 'If the ydotool smoke test typed "hello from ydotool" into your'
echo 'target window, the typing layer is unblocked and I will start on'
echo 'the daemon + KWin script + IPC next round.'
