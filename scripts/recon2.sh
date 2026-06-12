#!/usr/bin/env bash
# Follow-up probes after first recon. Focused on:
#   - why portal RemoteDesktop returned NotAllowed
#   - whether Screencast (sibling portal) refuses the same way
#   - whether ydotool is a viable fallback typing path
#
# Outputs to stdout + /tmp/vw-recon2.log. No typing happens.

set -u
LOG=/tmp/vw-recon2.log
: > "$LOG"
hdr() { printf '\n=== %s ===\n' "$*" | tee -a "$LOG"; }
run() { printf '$ %s\n' "$*" | tee -a "$LOG"; "$@" 2>&1 | tee -a "$LOG"; }

hdr 'xdg-desktop-portal-kde version'
# Try the package manager for whatever's there.
if command -v pacman >/dev/null 2>&1; then
  run pacman -Q xdg-desktop-portal xdg-desktop-portal-kde plasma-workspace kwin
fi

hdr 'kde.portal manifest (what interfaces does kde backend implement?)'
for path in /usr/share/xdg-desktop-portal/portals/kde.portal \
            /etc/xdg-desktop-portal/portals/kde.portal; do
  if [ -f "$path" ]; then
    printf '\n--- %s ---\n' "$path" | tee -a "$LOG"
    cat "$path" | tee -a "$LOG"
  fi
done

hdr 'portal hub config (which backend is selected for RemoteDesktop?)'
for path in /usr/share/xdg-desktop-portal/portals.conf \
            /usr/share/xdg-desktop-portal/kde-portals.conf \
            /etc/xdg-desktop-portal/portals.conf \
            ~/.config/xdg-desktop-portal/portals.conf; do
  if [ -f "$path" ]; then
    printf '\n--- %s ---\n' "$path" | tee -a "$LOG"
    cat "$path" | tee -a "$LOG"
  fi
done
printf 'XDG_CURRENT_DESKTOP=%s\n' "${XDG_CURRENT_DESKTOP:-<unset>}" | tee -a "$LOG"

hdr 'is there a system-wide "Location services" / privacy toggle?'
run gsettings list-schemas 2>/dev/null | grep -i 'location\|privacy' || true
# KDE side:
for path in ~/.config/kwinrc ~/.config/kdeglobals; do
  if [ -f "$path" ]; then
    printf '\n--- grep privacy/remote in %s ---\n' "$path" | tee -a "$LOG"
    grep -iE 'remote|location|privacy|screencast|screenshare' "$path" 2>/dev/null | tee -a "$LOG" || true
  fi
done

hdr 'Screencast portal sibling test'
cat <<'EOF' | tee -a "$LOG"
If Screencast also refuses, the deny is at the hub/policy level
(applies to all input-forwarding-style portals).
If Screencast works but RemoteDesktop refuses, the deny is
RemoteDesktop-specific (probably kde backend's own permission check).

Run:
    python3 /tmp/vw-recon-screencast.py
EOF

cat > /tmp/vw-recon-screencast.py <<'PY'
from gi.repository import GLib
from pydbus import SessionBus
import secrets

bus = SessionBus()
portal = bus.get('org.freedesktop.portal.Desktop', '/org/freedesktop/portal/desktop')
loop = GLib.MainLoop()
state = {}
token = secrets.token_hex(6)
sess_token = secrets.token_hex(6)

def watch(path, on_resp):
    bus.con.signal_subscribe(
        None, 'org.freedesktop.portal.Request', 'Response', path, None, 0,
        lambda *a: on_resp(a[5][0], a[5][1]))

def on_create(code, results):
    print(f'[create] code={code} results={dict(results)}')
    if code != 0: loop.quit(); return
    state['session'] = results['session_handle']
    rpath = portal.SelectSources(state['session'], {
        'types': GLib.Variant('u', 1),  # MONITOR
        'persist_mode': GLib.Variant('u', 2),
        'handle_token': GLib.Variant('s', f'sel_{token}'),
    })
    watch(rpath, on_sel)

def on_sel(code, results):
    print(f'[select] code={code} results={dict(results)}')
    if code != 0: loop.quit(); return
    rpath = portal.Start(state['session'], '', {
        'handle_token': GLib.Variant('s', f'start_{token}'),
    })
    watch(rpath, on_start)

def on_start(code, results):
    print(f'[start ] code={code} results={dict(results)}')
    print('SUCCESS: portal Screencast handshake works.')
    loop.quit()

try:
    req = portal.CreateSession({
        'handle_token': GLib.Variant('s', f'create_{token}'),
        'session_handle_token': GLib.Variant('s', f'sess_{sess_token}'),
    })
    print(f'create request: {req}')
    watch(req, on_create)
    GLib.timeout_add_seconds(60, lambda: (print('TIMEOUT'), loop.quit()))
    loop.run()
except Exception as e:
    print(f'EXCEPTION at CreateSession: {e}')
PY

hdr 'ydotool availability (fallback typing path)'
run pacman -Si ydotool 2>&1 | head -5
run pacman -Q ydotool 2>&1 || echo 'ydotool not installed (would need: pacman -S ydotool)'
run ls -l /dev/uinput 2>&1 || echo 'no /dev/uinput'
run getent group input 2>&1
printf 'current user in input group? ' | tee -a "$LOG"
id -nG | tr ' ' '\n' | grep -qx input && echo 'yes' | tee -a "$LOG" || echo 'no' | tee -a "$LOG"

hdr 'KWin script Workspace introspection (does KWin offer input emulation directly?)'
mkdir -p ~/.local/share/kwin/scripts/vw-recon2/contents/code
cat > ~/.local/share/kwin/scripts/vw-recon2/metadata.json <<'JSON'
{
    "KPackageStructure": "KWin/Script",
    "KPlugin": {
        "Id": "vw-recon2",
        "Name": "vw-autofill recon2",
        "Description": "Introspects KWin workspace API surface. Disable when done.",
        "Version": "1.0",
        "License": "MIT",
        "Authors": [{"Name": "vw-autofill"}]
    },
    "X-Plasma-API": "javascript",
    "X-Plasma-MainScript": "code/main.js"
}
JSON
cat > ~/.local/share/kwin/scripts/vw-recon2/contents/code/main.js <<'JS'
print('vw-recon2 starting');
function listKeys(obj, label) {
    var ks = [];
    for (var k in obj) ks.push(k);
    ks.sort();
    print('vw-recon2 ' + label + ' keys: ' + ks.join(','));
}
try { listKeys(workspace, 'workspace'); } catch (e) { print('vw-recon2 workspace err: ' + e); }
try {
    var w = workspace.activeWindow || workspace.activeClient;
    if (w) listKeys(w, 'activeWindow');
    else print('vw-recon2 no active window at startup');
} catch (e) { print('vw-recon2 active window err: ' + e); }
// Look for any input-emulation hooks.
var inputHooks = ['sendKey','sendKeyPress','sendInput','injectKey','typeText','simulate'];
for (var i = 0; i < inputHooks.length; i++) {
    var name = inputHooks[i];
    print('vw-recon2 has workspace.' + name + '? ' + (typeof workspace[name]));
}
JS
echo 'Enable "vw-recon2" in System Settings -> KWin Scripts.' | tee -a "$LOG"

hdr 'summary'
cat <<EOF | tee -a "$LOG"

1. Run:
     python3 /tmp/vw-recon-screencast.py

2. Enable "vw-recon2" KWin script in System Settings, then:
     journalctl --user --since "2 minutes ago" --no-pager | grep vw-recon2
   (and re-run the original KWin script the same way:
     journalctl --user --since "10 minutes ago" --no-pager | grep vw-recon
   the original log filter was wrong — my mistake.)
   Disable both when done.

3. Paste /tmp/vw-recon2.log plus the two outputs above.
EOF
