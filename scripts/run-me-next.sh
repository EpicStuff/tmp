#!/usr/bin/env bash
# Diagnose + fix the keyd / ydotool interaction.
#
# keyd grabs every keyboard-like /dev/input/event* it sees and
# re-emits through its own uinput sink. When ydotoold creates a
# new uinput device, keyd grabs that too, so ydotool's keystrokes
# get filtered through keyd's remapping layer first and can come
# out garbled.
#
# Fix: tell keyd to ignore ydotool's virtual device by its
# vendor:product ID via the [ids] section.

set -u
OUT=/tmp/vw-run-next.log
: > "$OUT"

pause() {
    printf '\n>>> %s\n' "$*"
    printf '>>> Press Enter when done. <<< '
    read -r _
}

cat <<'INSTRUCTIONS'
=== part 1: make sure ydotoold is running ===

In another terminal, start ydotoold (or check it's already up):

    sudo pkill -x ydotoold 2>/dev/null
    sudo ydotoold --socket-path=/tmp/.ydotool_socket --socket-perm=0666

Leave it running.
INSTRUCTIONS
pause 'after ydotoold is up'

echo
echo '=== part 2: identify ydotool virtual device ===' | tee -a "$OUT"
echo | tee -a "$OUT"

# /proc/bus/input/devices shows each input device with N: (name),
# I: (bus/vendor/product/version), H: (handlers). ydotool's
# virtual keyboard typically appears with name containing 'ydotool'.
echo '$ grep -B1 -A4 -i ydotool /proc/bus/input/devices' | tee -a "$OUT"
DEVICE_BLOCK=$(grep -B1 -A4 -i ydotool /proc/bus/input/devices || true)
echo "$DEVICE_BLOCK" | tee -a "$OUT"

if [ -z "$DEVICE_BLOCK" ]; then
    echo '(no ydotool device found - is ydotoold running?)' | tee -a "$OUT"
    echo 'aborting' | tee -a "$OUT"
    exit 1
fi

# Parse the I: line for vendor/product. Format:
# I: Bus=0006 Vendor=1234 Product=5678 Version=0001
INFO=$(printf '%s\n' "$DEVICE_BLOCK" | grep -m1 '^I:')
VENDOR=$(printf '%s\n' "$INFO" | sed -n 's/.*Vendor=\([0-9a-fA-F]\+\).*/\1/p')
PRODUCT=$(printf '%s\n' "$INFO" | sed -n 's/.*Product=\([0-9a-fA-F]\+\).*/\1/p')

if [ -z "$VENDOR" ] || [ -z "$PRODUCT" ]; then
    echo '(could not parse vendor/product from device block)' | tee -a "$OUT"
    exit 1
fi

# keyd's [ids] uses lowercase hex without 0x prefix.
VENDOR=$(printf '%s' "$VENDOR" | tr 'A-F' 'a-f')
PRODUCT=$(printf '%s' "$PRODUCT" | tr 'A-F' 'a-f')
PAIR="$VENDOR:$PRODUCT"
echo | tee -a "$OUT"
echo "ydotool device id (vendor:product) = $PAIR" | tee -a "$OUT"

echo
echo '=== part 3: current keyd config ===' | tee -a "$OUT"
ls /etc/keyd/ 2>&1 | tee -a "$OUT"
for f in /etc/keyd/*.conf; do
    [ -f "$f" ] || continue
    echo | tee -a "$OUT"
    echo "--- $f ---" | tee -a "$OUT"
    cat "$f" | tee -a "$OUT"
done

cat <<INSTRUCTIONS | tee -a "$OUT"

=== part 4: add exclusion to keyd config ===

Edit /etc/keyd/default.conf (or whichever .conf you actually use)
and ensure it has an [ids] section that excludes ydotool:

    [ids]
    *
    -$PAIR

If your config already has [ids] *, add the '-$PAIR' line.
If it has explicit IDs instead of '*', do nothing here — keyd
already isn't grabbing ydotool because it isn't in the include list.
If you don't have an [ids] section at all, prepend the three-line
block above to the file.

You can do this in any editor; example:

    sudoedit /etc/keyd/default.conf

After editing, reload keyd:

    sudo systemctl restart keyd

INSTRUCTIONS

pause 'after editing the config and restarting keyd'

echo
echo '=== part 5: verify exclusion ===' | tee -a "$OUT"
echo
echo 'systemd journal for keyd showing what it grabbed since restart:'
echo '$ journalctl -u keyd --since "1 minute ago" --no-pager' | tee -a "$OUT"
journalctl -u keyd --since '1 minute ago' --no-pager 2>&1 | tee -a "$OUT" || \
    echo '(journalctl access denied? run: sudo journalctl -u keyd --since "1 minute ago")' | tee -a "$OUT"

echo
echo '=== part 6: re-test ydotool ===' | tee -a "$OUT"
echo
echo '>>> Focus a safe target window (scratch editor / about:blank URL bar /'
echo '>>> empty terminal). Press Enter; typing fires in 3 seconds.'
read -r _
( sleep 3; YDOTOOL_SOCKET=/tmp/.ydotool_socket ydotool type 'hello from ydotool round two' ) &
wait $!
echo
printf 'Did "hello from ydotool round two" appear cleanly? (y/n/partial) '
read -r ANSWER
echo "user answer: $ANSWER" | tee -a "$OUT"

echo
echo "log: $OUT"
echo
echo 'Paste back:'
echo '  - /tmp/vw-run-next.log'
echo '  - whether ydotool now types cleanly'
