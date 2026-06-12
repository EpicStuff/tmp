#!/usr/bin/env bash
# Daemon end-to-end sanity check.
# 1. Build the binary.
# 2. Install/refresh the KWin watcher script in your KWin scripts dir.
# 3. Prompt you to enable + reload KWin scripts (System Settings click).
# 4. Prompt you to start the daemon (needs BW_SESSION; you do this).
# 5. Verify the daemon claimed the bus name, introspect it.
# 6. Ask you to focus several windows -> the KWin script pushes events
#    to the daemon, daemon log records them.
# 7. Ask you to run `vw_autofill fill` from a third terminal.
#
# This script never invokes sudo. Anything elevated is printed for you.

set -u
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
LOG=/tmp/vw-run-next.log
DLOG=/tmp/vw-autofill-daemon.log
: > "$LOG"

pause() {
    printf '\n>>> %s\n' "$*"
    printf '>>> Press Enter when done. <<< '
    read -r _
}

say() { echo "$*" | tee -a "$LOG"; }

say "=== part 1: build vw_autofill ==="
( cd "$ROOT" && nimble build 2>&1 ) | tee -a "$LOG"
if [ ! -x "$ROOT/bin/vw_autofill" ]; then
    say "build FAILED — see log above"
    exit 1
fi
say "build OK: $ROOT/bin/vw_autofill"
echo

say "=== part 2: install KWin watcher script ==="
SRC="$ROOT/data/kwin-script"
if ! command -v kpackagetool6 >/dev/null 2>&1; then
    say "kpackagetool6 not found — install plasma-workspace, then re-run"
    exit 1
fi
INSTALL_OUT=$(kpackagetool6 -t KWin/Script -i "$SRC" 2>&1)
echo "$INSTALL_OUT" | tee -a "$LOG"
if echo "$INSTALL_OUT" | grep -qi 'already exists'; then
    say "package already installed, upgrading..."
    kpackagetool6 -t KWin/Script -u "$SRC" 2>&1 | tee -a "$LOG"
fi
say "script source: $SRC"
say "installed copy: ~/.local/share/kwin/scripts/vw-autofill-watcher"
echo

say "=== part 3: enable + reload KWin scripts ==="
cat <<INSTRUCTIONS | tee -a "$LOG"

Open: System Settings -> Window Management -> KWin Scripts
Find "vw-autofill watcher" -> tick the box -> Apply.

Then reload KWin scripts so the change takes effect:

    qdbus6 org.kde.KWin /Scripting org.kde.kwin.Scripting.start

(If you only have qdbus, not qdbus6, just drop the 6.)

INSTRUCTIONS
pause 'after enabling + reloading'

say "=== part 4: start the daemon ==="
cat <<INSTRUCTIONS | tee -a "$LOG"

In a separate terminal, with your vault unlocked, run:

    export BW_SESSION="\$(bw unlock --raw)"
    YDOTOOL_SOCKET=/tmp/.ydotool_socket VW_AUTOFILL_LOG=$DLOG \\
        $ROOT/bin/vw_autofill daemon

Leave it running. (Also make sure ydotoold is still up from last round:
    pgrep -x ydotoold || sudo ydotoold --socket-path=/tmp/.ydotool_socket --socket-perm=0666 &
 )

INSTRUCTIONS
pause 'after starting daemon'

say
say "=== part 5: verify daemon owns the bus name ==="
if command -v busctl >/dev/null 2>&1; then
    if busctl --user list 2>/dev/null | grep -q org.vwautofill.Daemon; then
        say "bus name claimed: OK"
    else
        say "bus name NOT claimed — daemon didn't start, or BW_SESSION was missing"
    fi
elif command -v qdbus6 >/dev/null 2>&1; then
    if qdbus6 2>/dev/null | grep -q org.vwautofill.Daemon; then
        say "bus name claimed: OK"
    else
        say "bus name NOT claimed"
    fi
else
    say "no busctl/qdbus6 — skipping bus-name check"
fi

say
say "=== part 6: introspect the daemon object ==="
if command -v busctl >/dev/null 2>&1; then
    busctl --user introspect org.vwautofill.Daemon /org/vwautofill/Daemon 2>&1 \
        | tee -a "$LOG" | head -40 || true
fi

say
say "=== part 7: focus-event test ==="
cat <<INSTRUCTIONS

Click 3-4 different windows in sequence (any apps will do). The KWin
script pushes each focus change to the daemon; the daemon log will
show one line per activation.

INSTRUCTIONS
pause 'after clicking a few windows'

say
say "--- last 30 lines of daemon log ($DLOG) ---"
if [ -f "$DLOG" ]; then
    tail -n 30 "$DLOG" | tee -a "$LOG"
else
    say "no daemon log at $DLOG — VW_AUTOFILL_LOG may not have been set"
fi

say
say "=== part 8: Fill() test ==="
cat <<INSTRUCTIONS

Focus a safe scratch text field (about:blank URL bar, empty editor),
then in a *third* terminal run:

    $ROOT/bin/vw_autofill fill

If you have a vault item with a vw-autofill linapp:// rule whose exe
matches the focused window, it'll type the credential sequence.

If no rule matches, the daemon will log "no cached match, ignoring"
and nothing happens — that's expected, just means no test rule yet.

INSTRUCTIONS
pause 'after running fill'

say
say "--- last 10 lines of daemon log after Fill() ---"
if [ -f "$DLOG" ]; then
    tail -n 10 "$DLOG" | tee -a "$LOG"
fi

echo
echo "log: $LOG"
echo "daemon log: $DLOG"
echo
echo 'Paste back:'
echo "  - $LOG"
echo "  - anything weird that showed up in the daemon's own terminal"
