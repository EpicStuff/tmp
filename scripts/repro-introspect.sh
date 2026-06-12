#!/usr/bin/env bash
# Local reproduction of the introspect timeout.
# Starts an isolated session bus, runs vw_autofill with a stub rule set,
# then attempts busctl introspect to see what the daemon receives.
#
# No vault / bw needed: we patch BW_SESSION check out for this test.
set -eu
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"

cat <<'NOTE'
=== Reproducing introspect timeout in a private D-Bus session ===
NOTE

# Build a test driver that wires up Daemon with empty rules and serves.
TEST=/tmp/vw_test_daemon
cat > /tmp/vw_test_daemon.nim <<EOF
import vw_autofill/daemon
let d = newDaemon(@[], "/tmp/.ydotool_socket", "/tmp/vw-test-daemon.log")
d.serve()
EOF

nim c --hints:off --warnings:off --path:src -d:release \
    -o:"$TEST" /tmp/vw_test_daemon.nim 2>&1 | tail -5

: > /tmp/vw-test-daemon.log

# Run inside dbus-run-session so we get a private bus.
dbus-run-session -- bash -c '
  echo "session DBUS_SESSION_BUS_ADDRESS=$DBUS_SESSION_BUS_ADDRESS"
  # start daemon in background
  '"$TEST"' &
  D_PID=$!
  sleep 0.5

  echo
  echo "--- busctl --user list (looking for vwautofill) ---"
  busctl --user list 2>&1 | grep -E "NAME|vwautofill" || true

  echo
  echo "--- busctl --user introspect (5s timeout) ---"
  timeout 5 busctl --user introspect org.vwautofill.Daemon /org/vwautofill/Daemon 2>&1 || echo "(timed out or failed)"

  echo
  echo "--- daemon log so far ---"
  cat /tmp/vw-test-daemon.log

  kill $D_PID 2>/dev/null || true
  wait 2>/dev/null || true
'
