#!/usr/bin/env bash
# vw-autofill recon. Capability + sample probe to reduce
# round-trips before the Linux daemon slice lands.
#
# Run on your KDE Plasma 6 Wayland machine. Outputs to stdout
# and to /tmp/vw-recon.log. Safe: introspects D-Bus services
# and prompts you to focus a few windows; never types anything.

set -u
LOG=/tmp/vw-recon.log
: > "$LOG"

say() { printf '%s\n' "$*" | tee -a "$LOG"; }
hdr() { printf '\n=== %s ===\n' "$*" | tee -a "$LOG"; }
run() { say "\$ $*"; "$@" 2>&1 | tee -a "$LOG"; }
note() { printf '  # %s\n' "$*" | tee -a "$LOG"; }

# Pick gdbus/qdbus6 by what's present.
if command -v gdbus >/dev/null 2>&1; then DBUS=gdbus
elif command -v qdbus6 >/dev/null 2>&1; then DBUS=qdbus6
else say 'neither gdbus nor qdbus6 found — install one'; exit 2
fi
note "using $DBUS"

hdr 'D-Bus session bus reachable'
run $DBUS call --session --dest org.freedesktop.DBus --object-path /org/freedesktop/DBus \
  --method org.freedesktop.DBus.ListNames 2>&1 | tr ',' '\n' | grep -E 'portal|kwin|a11y|kde\.keyboard' | sort -u

hdr 'xdg-desktop-portal RemoteDesktop present + capabilities'
note 'introspect RemoteDesktop interface'
$DBUS introspect --session --dest org.freedesktop.portal.Desktop --object-path /org/freedesktop/portal/desktop \
  2>&1 | grep -A2 'interface name="org.freedesktop.portal.RemoteDesktop"' | tee -a "$LOG"
note 'AvailableDeviceTypes property'
$DBUS call --session --dest org.freedesktop.portal.Desktop \
  --object-path /org/freedesktop/portal/desktop \
  --method org.freedesktop.DBus.Properties.Get \
  org.freedesktop.portal.RemoteDesktop AvailableDeviceTypes 2>&1 | tee -a "$LOG"

hdr 'xdg-desktop-portal GlobalShortcuts present'
$DBUS introspect --session --dest org.freedesktop.portal.Desktop --object-path /org/freedesktop/portal/desktop \
  2>&1 | grep -A2 'interface name="org.freedesktop.portal.GlobalShortcuts"' | tee -a "$LOG"

hdr 'portal backend(s) installed'
for path in /usr/share/xdg-desktop-portal/portals /etc/xdg-desktop-portal/portals; do
  if [ -d "$path" ]; then
    note "$path:"
    ls -1 "$path" 2>/dev/null | tee -a "$LOG"
  fi
done
pgrep -af 'xdg-desktop-portal' 2>&1 | tee -a "$LOG"

hdr 'AT-SPI registry reachable'
$DBUS call --session --dest org.a11y.Bus --object-path /org/a11y/bus \
  --method org.a11y.Bus.GetAddress 2>&1 | tee -a "$LOG"

hdr 'active keyboard layout'
# Try a few ways depending on what's available.
if command -v localectl >/dev/null 2>&1; then
  run localectl status
fi
if command -v setxkbmap >/dev/null 2>&1; then
  run setxkbmap -query 2>/dev/null || true
fi
$DBUS call --session --dest org.kde.keyboard --object-path /Layouts \
  --method org.kde.KeyboardLayouts.getLayout 2>&1 | tee -a "$LOG" || true

hdr 'KWin script API probe'
cat <<'EOF' | tee -a "$LOG"
Drop the following file into:
    ~/.local/share/kwin/scripts/vw-recon/contents/code/main.js

And the metadata file alongside it:
    ~/.local/share/kwin/scripts/vw-recon/metadata.json

Then in System Settings -> Window Management -> KWin Scripts -> enable
"vw-recon". Focus any 2-3 windows of your choice. Then run:
    journalctl --user -t vw-recon -n 200 --no-pager
and paste the output.

When done, disable the script in System Settings.
EOF

mkdir -p ~/.local/share/kwin/scripts/vw-recon/contents/code
cat > ~/.local/share/kwin/scripts/vw-recon/metadata.json <<'JSON'
{
  "KPlugin": {
    "Id": "vw-recon",
    "Name": "vw-autofill recon",
    "Description": "Logs focused-window properties for recon. Disable when done.",
    "Version": "1",
    "Authors": [{"Name": "vw-autofill"}],
    "License": "MIT",
    "ServiceTypes": ["KWin/Script"]
  }
}
JSON

cat > ~/.local/share/kwin/scripts/vw-recon/contents/code/main.js <<'JS'
function dump(w, when) {
    if (!w) { print('vw-recon ' + when + ': null window'); return; }
    var keys = [];
    var pairs = [];
    var fields = ['caption','resourceClass','resourceName','pid','internalId',
                  'desktop','windowType','windowRole','windowClass'];
    for (var i = 0; i < fields.length; i++) {
        var k = fields[i];
        try {
            var v = w[k];
            if (typeof v === 'function') v = '[fn]';
            pairs.push(k + '=' + JSON.stringify(v));
        } catch (e) {
            pairs.push(k + '=<err:' + e + '>');
        }
    }
    print('vw-recon ' + when + ' ' + pairs.join(' '));
}
// Discover which event name exists on this KWin: workspace.windowActivated
// (KWin 6) vs workspace.clientActivated (KWin 5).
try {
    workspace.windowActivated.connect(function(w){ dump(w, 'windowActivated'); });
    print('vw-recon connected: workspace.windowActivated');
} catch (e) {
    print('vw-recon windowActivated not available: ' + e);
}
try {
    workspace.clientActivated.connect(function(w){ dump(w, 'clientActivated'); });
    print('vw-recon connected: workspace.clientActivated');
} catch (e) {
    print('vw-recon clientActivated not available: ' + e);
}
JS
note 'KWin script staged at ~/.local/share/kwin/scripts/vw-recon/'

hdr 'portal RemoteDesktop one-shot handshake'
cat <<'EOF' | tee -a "$LOG"
This runs a minimal CreateSession -> SelectDevices(KEYBOARD) -> Start
sequence. Triggers the one-time portal consent dialog (click "Allow"
when it appears). Does NOT type anything. Closes the session
immediately afterward.

Run separately:
    python3 /tmp/vw-recon-portal.py
EOF

cat > /tmp/vw-recon-portal.py <<'PY'
import os, secrets, sys
from gi.repository import GLib
from pydbus import SessionBus

bus = SessionBus()
portal = bus.get('org.freedesktop.portal.Desktop', '/org/freedesktop/portal/desktop')

loop = GLib.MainLoop()
state = {'step': None, 'session': None, 'result': {}}
token_h = secrets.token_hex(8)
token_s = secrets.token_hex(8)
sender = bus.get('org.freedesktop.DBus').GetNameOwner('org.freedesktop.portal.Desktop')
my_name = bus.con.get_unique_name().replace(':','_').replace('.','_')

def watch_request(path, on_response):
    bus.con.signal_subscribe(
        None, 'org.freedesktop.portal.Request', 'Response', path, None, 0,
        lambda *args: on_response(args[5][0], args[5][1]))

def on_create(code, results):
    print(f'[create] response code={code} results={dict(results)}')
    if code != 0: loop.quit(); return
    state['session'] = results['session_handle']
    rpath = portal.SelectDevices(state['session'],
        {'types': GLib.Variant('u', 1), 'persist_mode': GLib.Variant('u', 2),
         'handle_token': GLib.Variant('s', f'sel_{token_h}')})
    watch_request(rpath, on_select)

def on_select(code, results):
    print(f'[select] response code={code} results={dict(results)}')
    if code != 0: loop.quit(); return
    rpath = portal.Start(state['session'], '',
        {'handle_token': GLib.Variant('s', f'start_{token_h}')})
    watch_request(rpath, on_start)

def on_start(code, results):
    print(f'[start ] response code={code} results={dict(results)}')
    print('SUCCESS: portal RemoteDesktop handshake works.')
    loop.quit()

req = portal.CreateSession({
    'handle_token': GLib.Variant('s', f'create_{token_h}'),
    'session_handle_token': GLib.Variant('s', f'sess_{token_s}'),
})
print(f'create request path: {req}')
watch_request(req, on_create)

GLib.timeout_add_seconds(60, lambda: (print('TIMEOUT after 60s'), loop.quit()))
try:
    loop.run()
except KeyboardInterrupt:
    pass
PY
note 'portal probe staged at /tmp/vw-recon-portal.py'
note 'needs python-pydbus and python-gobject. on Arch: pacman -S python-pydbus python-gobject'

hdr 'summary'
cat <<EOF | tee -a "$LOG"

Steps to complete this recon (paste outputs back):

  1. Output above (already collected in $LOG).
  2. Enable the KWin script in System Settings, focus 2-3 windows of
     your choice (any apps), then:
         journalctl --user -t vw-recon -n 200 --no-pager
     ...and disable the script when done.
  3. Run the portal probe:
         pacman -S python-pydbus python-gobject   # if not installed
         python3 /tmp/vw-recon-portal.py
     Click "Allow" on the portal consent dialog when it appears.

Paste the contents of $LOG plus the journalctl output and the portal
probe output.
EOF