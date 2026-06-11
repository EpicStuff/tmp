# vaultwarden-autofill — Plan (Option B: Nim everywhere)

Cross-platform desktop autofill daemon, single Nim codebase, backed by
Bitwarden/Vaultwarden via `bw` CLI. Targets Linux (KDE Plasma 6 Wayland)
and Windows (no admin), built from Linux via MinGW cross-compilation.

This is the plan if Option A (AHK on Windows) is ruled out, e.g. by
school IT blocking AHK. Option A may still come back if the user
decides AHK is reachable; that would replace the Windows slices
(currently 7 / 8 / 9) with AHK setup and leave the Linux slices
unchanged.

---

## 1. Scope

**In for v1**

- Linux: KDE Plasma 6 on Wayland. Window activation events via KWin
	script. Typing via `xdg-desktop-portal` RemoteDesktop by default
	(fully user-mode); `ydotool` as an opt-in fallback. Field-type
	detection via AT-SPI.
- Windows: `SetWinEventHook(EVENT_SYSTEM_FOREGROUND)`, `SendInput`,
	UI Automation COM, `RegisterHotKey`. No admin required.
- Vault backend: `bw` CLI on both platforms. Abstracted so `rbw` can
	swap in later on Linux.
- Rule storage: **everything in URIs** on the Bitwarden login item
	using `winapp://` / `linapp://` / `app://` schemes. Matchers
	(`title`, `title_regex`, `class`, `text`) and behavior (`mode`,
	`sequence`, `cooldown`, `field_check`, `unsafe`) all live as URI
	query params. No `autofill.*` custom fields. Same convention as
	bitwarden-autotype, extended with regex / subtree-text matching
	and behavior params. One login may have **many URIs** so the
	credential fires across multiple windows, each URI carrying its
	own behavior (see §8).
- Capture-driven CLI to add / edit URIs (no GUI).
- Two trigger modes **per URI** (set via the URI's `mode=` query
	param): `hotkey` (default) and `auto` (opt-in, used for F5
	nice-to-have).

**Out for v1**

- TOTP autofill — easy add later, not core path.
- GUI rule editor — CLI only.
- macOS.
- Wayland compositors other than KWin.
- X11 / XWayland targeting (incidentally works on Windows-style apps
	via the Windows path; not a goal on Linux).
- Installer / MSI. Distribution is a portable folder.

---

## 2. Locked-in decisions

| Area | Linux | Windows |
|---|---|---|
| Language | Nim (release mode, no UPX, no `-d:danger`) | Nim (release mode, no UPX, no `-d:danger`) |
| Build | Native (Nim + gcc) | Cross-compiled from Linux via `mingw-w64`; `windres` for resources |
| Vault CLI | `bw`, resolved via `bw_path` config → PATH → daemon-binary dir | `bw.exe`, resolved via `bw_path` config → PATH → daemon-binary dir |
| Vault interface | `VaultBackend`; `rbw` could swap in later | `VaultBackend`; `bw` only (no Windows binary for `rbw`) |
| Rule storage | URIs on the login item (`winapp://` / `linapp://` / `app://`); matchers and behavior both in URI query params; no custom fields. Many URIs per item = many windows sharing one credential, each with its own behavior (see §8). | Same — same vault, same conventions; cross-compatible with bitwarden-autotype on the matching subset. |
| Config format | Local YAML via `nyml` | Same |
| Hotkey | KDE custom shortcut → `vw-autofill fill` → IPC (sidesteps Wayland) | `RegisterHotKey` in-process; defaults `Ctrl+Alt+B` / `Ctrl+Shift+;` |
| Typing | `xdg-desktop-portal` RemoteDesktop (default, fully user-mode); `ydotool` opt-in fallback | `SendInput` with `KEYEVENTF_UNICODE`; no admin needed |
| Window detect | KWin script (in-compositor) → D-Bus event with `pid` / `caption` / `resourceClass` | `SetWinEventHook(EVENT_SYSTEM_FOREGROUND, …, WINEVENT_OUTOFCONTEXT)` |
| Field detect | AT-SPI over D-Bus (Qt/GTK/Firefox); degrades gracefully if absent | UI Automation COM (`IUIAutomation`); broad coverage including Trident/WebView2/CEF/Electron |
| Master password | Daemon never touches it; user runs `bw unlock --raw \| vw-autofill unlock`. Interactive helper spawns Konsole/$TERMINAL running that pipeline. Notification triggers helper. | Same model: helper spawns Windows Terminal (or cmd.exe) running the pipeline; toast notification triggers helper. |
| IPC | D-Bus session bus, `org.user.VwAutofill` / `/Daemon` | Named pipe `\\.\pipe\vw-autofill` |
| Privilege | Fully user-mode with portal; ydotool path needs `input` group (one-time admin udev rule) | No admin required |
| AV posture | n/a | Unsigned; embedded manifest + version info + icon; target ~500 KB – 1.5 MB |
| Smoke target | PyQt6 two-field app + JSON log | tkinter two-field app + JSON log |
| Auto-tests | Comprehensive — unit, integration with fakes, property tests, smoke; see §18 | Same suite, cross-built and run on a Windows target |

---

## 3. Architecture overview

Single Nim binary `vw-autofill` with subcommands:

```
vw-autofill daemon              # long-running: hotkey + window events
vw-autofill fill                # one-shot: signal daemon to fill now
vw-autofill unlock              # read session token from stdin, hand to daemon
vw-autofill unlock-interactive  # spawn terminal running 'bw unlock --raw | vw-autofill unlock'
vw-autofill add                 # interactive capture flow (this terminal)
vw-autofill add-interactive     # spawn terminal running 'vw-autofill add'
vw-autofill list                # list configured rules
vw-autofill edit <name>         # tweak a rule
vw-autofill delete <name>       # remove a rule from an item
vw-autofill status              # daemon health, last fire, last error
vw-autofill snapshot            # print current foreground snapshot (debug)
vw-autofill match               # print which rules would match the foreground
vw-autofill fill --dry-run      # render the sequence ops but don't type
vw-autofill doctor              # environment self-check, see §15a
vw-autofill enable-autostart
vw-autofill disable-autostart
vw-autofill install-kwin-script    # Linux only
vw-autofill uninstall-kwin-script  # Linux only
```

`daemon` is the long-running process. Every other subcommand is a
tiny client that talks to `daemon` via local IPC. The daemon
**never owns a terminal**; all interactive prompts (unlock, add,
edit) happen in the client process, which is run by the user in any
terminal — or spawned for them via the `-interactive` variants.

The debug trio (`snapshot`, `match`, `fill --dry-run`) prints the
daemon's current view of the world without typing anything:

- `snapshot` → exe path, exe basename, title, class, focused-field
	role, focused-field text hints.
- `match` → list of rules that would fire against the current
	foreground, with the matching dimensions called out.
- `fill --dry-run` → renders the chosen rule's sequence to ops
	(`{TYPE: 'alice'}`, `{KEY: Tab}`, `{TYPE: '…'}`, `{KEY: Enter}`)
	and prints them instead of dispatching to the typer.

These are the first thing to reach for when something doesn't fire
— way faster than tailing daemon logs.

**IPC**:

- Linux: D-Bus session bus, name `org.user.VwAutofill`, path `/Daemon`.
- Windows: named pipe `\\.\pipe\vw-autofill`.

Both wrapped behind a `Bus` interface so call sites are
platform-agnostic.

---

## 4. User experience

A walkthrough of the lifecycle a user will go through, top to bottom.
Treat this as the spec for how the surface should feel.

### 4.1. First-time setup (one-time, ~5 minutes)

1. Place `vw-autofill` (Linux) or `vw-autofill.exe` (Windows) into a
	folder the user can write — e.g. `~/.local/bin/` or
	`%LOCALAPPDATA%\Programs\vw-autofill\`.
2. Make sure the Bitwarden CLI is reachable. Resolution order is
	**`bw_path` in `config.yaml` → PATH → daemon-binary directory**
	— so an explicit `bw_path` always wins.
	- Linux: `pacman -S bitwarden-cli` puts `bw` on PATH and you're
		done.
	- Windows (no admin): drop `bw.exe` anywhere on your PATH, or
		next to `vw-autofill.exe`, or pin it with `bw_path:
		C:\Tools\bw.exe` in config.
3. Configure the vault:
	```
	bw config server https://your.vaultwarden.host
	bw login
	```
4. Linux-only setup:
	```
	vw-autofill install-kwin-script
	# Prints: "Open System Settings → Window Management → KWin Scripts
	#          and tick 'vw-autofill'."
	```
	No root is required. By default the daemon types via the
	`xdg-desktop-portal` RemoteDesktop interface (KDE Plasma 6.3+);
	on first fill you'll get a one-time KDE consent dialog,
	"Allow vw-autofill to control keyboard and mouse?" Tick "Remember
	choice" and approve. The portal returns a restore token the
	daemon caches in its config dir so the prompt doesn't reappear.
	If your distro doesn't ship `xdg-desktop-portal-kde` or you'd
	rather use `ydotool`, see §12.1.
5. Bind hotkeys:
	- Linux: System Settings → Shortcuts → Custom Shortcuts. Two
		entries:
		- `Ctrl+Alt+B` → runs `vw-autofill fill`
		- `Ctrl+Shift+;` → runs `vw-autofill add`
	- Windows: hotkeys are registered in-process by the daemon,
		defaults read from `config.yaml`.
6. Enable autostart:
	```
	vw-autofill enable-autostart
	```
	- Linux: prefers a **systemd `--user` service**
		(`~/.config/systemd/user/vw-autofill.service`) on systemd
		systems — gives proper journal logging and restart-on-crash;
		falls back to `~/.config/autostart/vw-autofill.desktop` on
		non-systemd setups.
	- Windows: writes `HKCU\Software\Microsoft\Windows\CurrentVersion\Run`.
7. Start the daemon:
	```
	vw-autofill daemon
	```
	On first run the daemon sees no session token, finds the vault
	locked, and posts a desktop notification: "vw-autofill: vault
	locked — click to unlock." Clicking it spawns a terminal running
	`bw unlock --raw | vw-autofill unlock`; you enter the master
	password into bw's own prompt (not into anything written by us)
	and the daemon receives the resulting session token over IPC.
	See §13.1 for the full flow.
8. Or unlock manually in any terminal:
	```
	bw unlock --raw | vw-autofill unlock
	```
	Same effect. Useful over SSH or when you'd rather not click a
	notification.

### 4.2. Daemon startup behavior

```
$ vw-autofill daemon
[2026-06-11 14:02:11] INFO daemon: loading config from ~/.config/vw-autofill/config.yaml
[2026-06-11 14:02:11] INFO vault: bw status: unlocked (cached session)
[2026-06-11 14:02:12] INFO rules: loaded 3 rules from 47 vault items
[2026-06-11 14:02:12] INFO bus: D-Bus name acquired: org.user.VwAutofill
[2026-06-11 14:02:12] INFO daemon: ready
```

If locked, the daemon posts an unlock notification (see §13.1) and
waits. The user can also unlock manually at any time:

```
bw unlock --raw | vw-autofill unlock
```

### 4.3. Adding your first rule — F5 BIG-IP Edge Client

The capture wizard is a *client* process that runs in your terminal.
The intended path is: focus the target window, press the capture
hotkey, the snapshot is what was focused at that moment, then a
terminal opens for the prompts. No second hotkey press.

1. Open the F5 client. Get to its login window. Click into the
	username field — make sure it's focused.
2. Press the capture hotkey (`Ctrl+Shift+;`). On Linux this is a KDE
	custom shortcut you bind to `vw-autofill add-interactive`; on
	Windows it's a daemon-owned global hotkey. Either way, the daemon
	snapshots the foreground **immediately**, then a terminal opens
	running `vw-autofill add --use-pending=<id>`.
3. Back in the spawned terminal:

	```
	[snapshot from daemon]
	  exe (full):    C:\Program Files (x86)\F5 VPN\f5fpclientW.exe
	  exe basename:  f5fpclientW.exe
	  title:         F5 BIG-IP Edge Client Logon
	  class:         ATL:0042B7F0
	  focused field: Edit (IsPassword = false)
	  dialog text:   "Server: vpn.school.edu | Username:"

	Match on exe:
	[1] full path  ← default (strictest, recommended)
	[2] basename only  (portable across install paths; looser)
	Pick [1]: <enter>

	Additional matchers (URI query attrs):
	[1] title_regex           ← suggested
	[2] class
	[3] title_regex + class
	[4] title_regex + text
	[5] none (exe alone — requires unsafe=1)
	Pick [1]: <enter>

	Bitwarden entry (type to filter, Tab to autocomplete):
	> school_
	  School VPN
	  School Email
	Pick: School VPN <enter>

	This item has 0 existing autofill URIs. Adding new URI.

	Mode (for this URI):
	[1] hotkey   ← default
	[2] auto     ← fires on window activation, no hotkey
	Pick [2]: <enter>

	Sequence:
	[1] $user$tab$pass$enter   ← default
	[2] $user$tab$pass
	[3] $pass$enter
	[4] custom...
	Pick [1]: <enter>

	Reading current 'School VPN' item via 'bw get item' ...
	Appending URI to .login.uris:
	  winapp:///C%3A/Program%20Files%20(x86)/F5%20VPN/f5fpclientW.exe?title_regex=%5EF5%20BIG-IP.*Logon%24&mode=auto
	Encoding via 'bw encode' and writing via 'bw edit item' ...
	✓ Active. Open the F5 login window and watch the daemon fill.
	```

5. Done. The 'School VPN' item now carries one extra URI on its
	`.login.uris` list. Subsequent windows that should fire the
	**same credential** are added as additional URIs on this same
	vault item (each with its own behavior — see §8.2).

### 4.4. Daily use — hotkey path (browser HTTP-auth example)

1. Browse to a site that triggers the browser HTTP Basic auth dialog
	(e.g. `https://cotauth.toronto.ca`).
2. Dialog appears with focus already on the username field — that's
	the default.
3. Press fill hotkey (`Ctrl+Alt+B`).
4. Daemon detects: `firefox` (exe) + `MozillaDialogClass` (class) +
	dialog text contains `cotauth.toronto.ca` → unique match for
	"School Auth" rule → types user, Tab, password, Enter.
5. Browser receives the auth and continues.

### 4.5. Daily use — auto path (F5 VPN)

1. Click F5 tray icon → Connect.
2. F5 client raises its login window. Daemon's `windowActivated` hook
	fires.
3. Daemon matches the rule, re-verifies foreground hasn't changed,
	checks cooldown, types `$user$tab$pass$enter`.
4. F5 connects.

The user does not press any key.

### 4.6. Status / introspection

```
$ vw-autofill status
daemon:   running, pid 12345, up 1h 14m
vault:    unlocked (bw status: unlocked)
rules:    3 loaded
last fire: 'School VPN' 12s ago (auto, window: F5 client)
last skip: 'School Auth' 4m ago (cooldown 11s remaining)
errors:   0
```

```
$ vw-autofill list
School VPN
  winapp:///C:/Program Files (x86)/F5 VPN/f5fpclientW.exe
    title_regex: ^F5 BIG-IP.*Logon$
    mode: auto   seq: $user$tab$pass$enter   cooldown: 15s

School Auth
  linapp://firefox
    class: MozillaDialogClass
    text:  cotauth.toronto.ca
    mode: hotkey   seq: $user$tab$pass$enter   cooldown: 15s
```

### 4.7. Editing or removing rules

```
vw-autofill edit "School VPN"     # interactive: pick a URI to modify
vw-autofill delete "School VPN"   # removes one URI (interactive pick), or all matching URIs
```

Or edit the URI list directly in Bitwarden's web/desktop UI — daemon
will reload on next vault sync (`bw sync`).

### 4.8. Edge cases the user will encounter

| What happens | Why | User action |
|---|---|---|
| Hotkey pressed, nothing happens | No rule matched the focused window | `vw-autofill status` shows last decision. Run `vw-autofill add`. |
| Hotkey pressed, ambiguous-match log | Two URIs match across different items | Narrow one: add `class=` or `text=` to the URI |
| Defender flags `vw-autofill.exe` | Heuristic on unsigned PE | Per-user exclusion; submit to MS false-positive form |
| Master password expired (session token stale) | `bw` reports locked | Daemon posts an unlock notification; click it, or run `bw unlock --raw \| vw-autofill unlock` |
| Wrong field got typed into | Focus moved between capture and type | Daemon's re-verify check should suppress; if not, raise an issue |
| Capture failed: "no focused element" | AT-SPI / UIA didn't report focus | Re-click the field, press capture hotkey again |

### 4.9. Removal

```
vw-autofill disable-autostart
vw-autofill stop
vw-autofill uninstall-kwin-script   # Linux only
rm -rf ~/.config/vw-autofill        # or %APPDATA%\vw-autofill on Windows
# vault items keep their winapp:// URIs — inert without the daemon
```

---

## 5. File layout

```
vaultwarden-autofill/
├── src/
│   ├── vwautofill.nim         # main, command dispatch
│   ├── vault.nim              # VaultBackend interface + Bw impl
│   ├── rules.nim              # URI parsing (matchers + behavior), match logic
│   ├── seq_template.nim       # $user$tab$pass$enter renderer
│   ├── match.nim              # rule-matching against window state
│   ├── capture.nim            # interactive add flow
│   ├── config.nim             # local YAML config
│   ├── log.nim                # structured logging
│   ├── bus.nim                # IPC interface (platform-dispatched)
│   ├── bus_linux.nim          # D-Bus impl
│   ├── bus_windows.nim        # named pipe impl
│   ├── platform.nim           # platform interface
│   ├── platform_linux.nim     # KWin event recv, portal/ydotool typing, AT-SPI
│   ├── platform_windows.nim   # WinEventHook, SendInput, UIA, hotkey
│   └── platform_windows_uia.nim  # IUIAutomation COM wrappers
├── kwin-script/
│   ├── metadata.json          # KWin script metadata
│   └── contents/code/main.js  # workspace.windowActivated handler
├── packaging/
│   ├── windows/
│   │   ├── manifest.xml       # asInvoker
│   │   ├── version.rc         # PE resource (CompanyName etc.)
│   │   └── icon.ico
│   └── linux/
│       └── vw-autofill.desktop
├── tests/
│   ├── test_rules.nim
│   ├── test_seq_template.nim
│   ├── test_vault_parse.nim
│   ├── test_match.nim
│   ├── test_capture.nim
│   ├── test_bus_linux.nim
│   ├── test_bus_windows.nim   # compiled only when --os:windows
│   ├── test_platform_linux.nim
│   ├── test_platform_windows.nim
│   ├── test_integration.nim
│   ├── fixtures/
│   │   ├── bw_items_sample.json
│   │   ├── bw_item_with_rules.json
│   │   └── kwin_event_payloads.json
│   ├── harness/
│   │   ├── fake_vault.nim
│   │   ├── fake_platform.nim
│   │   └── fake_bus.nim
│   └── smoke/                 # Python test targets
│       ├── target_linux.py    # PyQt6 two-field app with JSON log
│       ├── target_windows.py  # tkinter two-field app with JSON log
│       ├── basic_auth_server.py  # 401 challenger for HTTP-Basic tests
│       └── run_smoke.sh
├── tools/
│   ├── check.sh               # run everything: nim check, tests, builds
│   ├── build-windows.sh       # cross-compile + windres
│   └── proof/                 # Slice 0 throwaway demos
│       ├── kwin-event/
│       ├── portal-type/
│       ├── atspi-focus/
│       └── win-sendinput/
├── nim.cfg
├── nim-mingw.cfg              # cross-compile config
├── vw-autofill.nimble
└── PLAN.md                    # this file
```

---

## 6. Dependencies

**Nim packages** (via `nimble`):

- `winim` — Win32 + COM bindings. Used only on Windows builds.
- `nyml` (openpeeps/nyml) — YAML config parsing. Smaller and simpler
	than NimYAML; <https://github.com/openpeeps/nyml>.
- A D-Bus binding — candidate: hand-rolled via `libdbus` FFI, or use
	one of the existing `nim-dbus`-style packages. Decide at slice 2.
	Hand-rolled is ~100 lines and avoids a dep.
- `unittest2` — test runner (richer than stdlib `unittest`, supports
	parameterized cases).
- stdlib otherwise: `json`, `osproc`, `streams`, `tables`,
	`strutils`, `re`, `posix` (Linux), `winlean` (Windows).

**External binaries (user-installed)**:

- `bw` / `bw.exe` — Bitwarden CLI. Resolved in order: `bw_path` in
	config (wins if set), then PATH, then the daemon-binary directory.
	No "place next to me" requirement.
- KDE Plasma 6 with `xdg-desktop-portal-kde` — Linux (default
	typing/input backend; ships standard on KDE 6.3+).
- *Optional*: `ydotool` + `ydotoold` — Linux fallback typing
	backend, only required if `typing_backend: ydotool` is set.
	Needs `/dev/uinput` access (udev rule that puts the user in
	`input` group is one-time admin; after that, no root).
- *Optional*: a terminal emulator the user has installed
	(`konsole`, `gnome-terminal`, `alacritty`, `xterm`, or whatever
	`$TERMINAL` points at) — used by `unlock-interactive` and
	`add-interactive`. Falls back gracefully.

**Test-only dependencies** (not shipped with the daemon):

- Python 3 — runs the smoke-target apps.
- `PyQt6` — Linux target app.
- `tkinter` — bundled with Python on Windows; used by the Windows
	target app.
- Python stdlib `http.server` for the HTTP-Basic test server. No
	extra installs needed.

---

## 7. Cross-compilation

Build host: Linux. Tool: `mingw-w64`.

`nim-mingw.cfg`:

```ini
amd64.windows.gcc.exe = 'x86_64-w64-mingw32-gcc'
amd64.windows.gcc.linkerexe = 'x86_64-w64-mingw32-gcc'
```

Build commands:

```
# Linux native
nim c -d:release --opt:speed -o:build/vw-autofill src/vwautofill.nim

# Windows cross
nim c -d:release --opt:speed --os:windows --cpu:amd64 \
	--cc:gcc --gcc.exe:x86_64-w64-mingw32-gcc \
	--gcc.linkerexe:x86_64-w64-mingw32-gcc \
	--passL:packaging/windows/version.res \
	-o:build/vw-autofill.exe src/vwautofill.nim
```

Resource compilation (run before nim build):

```
x86_64-w64-mingw32-windres packaging/windows/version.rc \
	-O coff -o packaging/windows/version.res
```

`version.rc` embeds icon, version info, and the manifest.

---

## 8. Rule schema

**Everything lives in URIs on the login item.** Each URI on
`.login.uris` is a self-contained rule: the matchers *and* the
behavior settings are all in the URI's query string. No `autofill.*`
custom fields, no item-level rule configuration. Custom fields are
left for the user's own use.

If the same credential needs to fire across multiple windows
(F5 client + browser HTTP-auth dialog + alternate VPN window), add
**multiple URIs** to the single login item. Each URI carries its own
behavior, so two URIs on the same item can — and often will — have
different modes / sequences / cooldowns. This is a feature: one
credential, many windows, each window handled exactly as it needs.

This matches the bitwarden-autotype URI convention with extensions,
so a Windows machine running stock bitwarden-autotype against the
same vault would still recognize the matching subset (extensions
ignored gracefully).

### 8.1. URI grammar

Each URI on a login item is one self-contained rule. Schemes:

| Scheme | Matches on |
|---|---|
| `winapp://...` | Windows only |
| `linapp://...` | Linux only |
| `app://...` | Either OS (matches against the local OS's exe) |

URI body:

```
<scheme>://<exe>?<key>=<value>&<key>=<value>...
```

- `<exe>` is one of:
	- empty (no exe matcher; query attrs alone gate the match — e.g.
		`winapp://?class=MozillaDialogClass&text=cotauth.toronto.ca`)
	- a basename, e.g. `f5fpclientW.exe`, `firefox`
	- a full path, encoded with the standard URI triple-slash
		convention, e.g.
		`winapp:///C%3A/Program%20Files/F5%20VPN/f5fpclientW.exe`,
		`linapp:///usr/lib/firefox/firefox`

Query attrs split into **matchers** (gate whether this URI fires) and
**behavior** (what happens when it fires). The sequence template (§9)
is designed to need no percent-encoding for the common cases, so the
behavior params stay readable in Bitwarden's UI.

**Matcher attrs:**

| Key | Meaning |
|---|---|
| `title` | Exact window-title match |
| `title_regex` | POSIX regex match against window title (our extension) |
| `class` | Window class / `resourceClass` exact match |
| `text` | Substring match against the UIA / AT-SPI subtree text around the focused element (our extension) |

**Behavior attrs** (all optional; missing = compiled-in default from
the config):

| Key | Default | Meaning |
|---|---|---|
| `mode` | `hotkey` | `hotkey` \| `auto`. `auto` fires on window activation; `hotkey` waits for the fill hotkey. |
| `sequence` | `$user$tab$pass$enter` | Sequence template; see §9. Designed to stay URI-safe without encoding. |
| `cooldown` | `15` (config: `default_cooldown_s`) | Seconds. Suppress refire on the same `(URI, window)` within this window. |
| `field_check` | `any` | `any` \| `text` \| `password`. Required focused-element role gate. |
| `unsafe` | absent | `unsafe=1` allows this URI to match with exe alone (no title/class/text). Required for `auto` would also need a `title_regex`/`class`/`text`. |

Behavior is **per URI**, not per item. The same credential on two
URIs can fire one in `auto` mode and the other in `hotkey` mode, with
different sequences if needed.

### 8.2. Examples

**F5 BIG-IP Edge Client (Windows, auto-fire)**

A login item "School VPN" with one URI:

```
winapp:///C%3A/Program%20Files%20(x86)/F5%20VPN/f5fpclientW.exe?title_regex=%5EF5%20BIG-IP.*Logon%24&mode=auto
```

**Same credential, also matches the F5 web SSO popup (auto too)**

Same "School VPN" item, second URI:

```
winapp://?class=MozillaDialogClass&text=vpn.school.edu&mode=auto
```

Both URIs are on one item — one credential, two windows, both in
`auto` mode (independently declared per URI).

**Firefox HTTP Basic auth dialog at cotauth.toronto.ca, Linux,
hotkey-only**

A different login item "School Auth" (different credential):

```
linapp://firefox?class=MozillaDialogClass&text=cotauth.toronto.ca
```

(No behavior params set → uses defaults: `mode=hotkey`,
`sequence=$user$tab$pass$enter`.)

**Same credential, mixed modes (deliberate per-URI difference)**

A "Mail" login that auto-fires in the Thunderbird login dialog but
only hotkey-fires in the browser:

```
linapp://thunderbird?class=Thunderbird&text=imap.school.edu&mode=auto
linapp://firefox?class=MozillaDialogClass&text=mail.school.edu
```

This was awkward / impossible in the old item-level-behavior design;
the URI-only design makes it natural.

### 8.3. Match semantics

For each URI on each item:

1. Check scheme matches the current OS.
2. Check exe matches the foreground process (full path if the URI
	used one, otherwise basename).
3. Check every matcher attr (`title`, `title_regex`, `class`, `text`)
	matches the foreground state.
4. If all checks pass, this URI is a candidate.

After collecting candidates across all items:

- **0 candidates**: no fill (optionally fall through to a picker if
	`fallback_picker: true`).
- **1 candidate**: fire it with that URI's behavior.
- **2+ candidates on the same item**: same credential, no ambiguity
	for the *user*. Fire once with the candidate that has the most
	matcher attrs (most specific wins); tie → use the URI listed
	first.
- **2+ candidates across different items**: ambiguous match —
	daemon logs the contenders and does nothing. The user resolves
	by tightening matchers.

Exe comparison: case-insensitive on Windows, case-sensitive on
Linux. Full-path comparison uses the literal string after URI
decode; symlinks are not resolved (capture stores what
`/proc/<pid>/exe` or `QueryFullProcessImageNameW` returned).

### 8.4. Validation

At rule-load time, per URI:

- URI parses (valid scheme, query syntax, regex compiles, sequence
	template parses, `mode` is one of the known values, `cooldown` is
	a non-negative integer, `field_check` is one of the known values).
- For URIs with `mode=auto`: **exe + (title or title_regex or class
	or text)** — at least one matcher beyond the exe. Refuse to enable
	`auto` otherwise.
- For URIs with `mode=hotkey` (or default): exe-only URIs are
	allowed *only* if `unsafe=1` is set on the same URI.
- A URI that fails validation is skipped with a logged warning; the
	rest of the item's URIs (and other items) still load.

### 8.5. Cross-tool compatibility

The matching subset (URI schemes, `?title=`, `?class=`, full-path
vs basename) is interoperable with stock bitwarden-autotype on
Windows. Behavior extensions (`?mode=`, `?sequence=`, `?cooldown=`,
`?field_check=`, `?unsafe=`) and matcher extensions (`?title_regex=`,
`?text=`) are ignored by bitwarden-autotype but don't break it. If
the user ever moves to a Windows machine where AHK is available,
the same vault works for both tools.

---

## 9. Sequence template language

Designed so the entire template is URI-safe with no percent-encoding —
the template ships inside the `sequence=` query param of an autofill
URI (see §8), and the chars used (`$`, `:`, letters, digits) are all
in RFC 3986's unreserved / sub-delim sets.

Tokens recognized in `sequence=`:

| Token | Meaning |
|---|---|
| `$user` | item's username |
| `$pass` | item's password |
| `$totp` | computed TOTP (v1.1, not v1) |
| `$field:Name` | value of a same-item custom field named `Name` |
| `$tab` | Tab key |
| `$enter` | Enter key |
| `$shifttab` | Shift+Tab |
| `$delay:N` | wait N ms before next token |
| `$key:Name` | named key, e.g. `$key:f2` |

Token names are case-insensitive. Any text between tokens is typed
literally — e.g. `prefix-$user@example.com$tab$pass$enter` types
`prefix-`, then the username, then `@example.com`, then Tab, etc.
A literal `$` in the template is escaped as `$$`.

**Parser:**

- Walk left-to-right. Scan literal text up to the next `$` or end.
- At `$`: if `$$`, emit literal `$` and continue.
- Else read `[A-Za-z]+` as the token name.
- If the next char is `:`, read `[^$]*` as the parameter value (greedy
	up to next `$` or end-of-string); the parameter ends *before* the
	`$`, never includes it. To put a literal `$` inside a parameter
	value, use `$$`.
- Otherwise the token has no parameter.

**Examples:**

```
$user$tab$pass$enter                  → classic
$user$tab$pass$delay:500$enter        → 500ms pause before Enter
$user@example.com$tab$pass$enter      → literal email suffix
$$5 charge$tab$pass$enter             → types '$5 charge' then tab + pass + enter
$field:apiKey$enter                   → look up custom field 'apiKey'
```

Implementation: tokenize once at rule-load time into a list of
`SeqOp = enum opText, opType, opKey, opDelay`. Renderer walks ops and
emits to the platform typer.

---

## 10. Capture flow

See §4.3 for the user-facing walkthrough. Architectural rules:

- **The client owns the prompts.** `vw-autofill add` runs in the
	user's terminal (or in a terminal spawned by `add-interactive` /
	the notification action). The daemon never owns a TTY.
- **The daemon owns the snapshot.**
- **Interactive prompts** are plain stdio in the client (no TUI
	library). Arrow-key + numeric input; zero deps.
- **Writeback** uses the correct `bw` pipeline (see §13.2): `bw get
	item <id>` → modify JSON in place (append, replace, or remove a
	URI on the item's `.login.uris` list) → pipe through `bw encode`
	→ `bw edit item <id>`. The client *requests* this through the
	daemon so only the daemon ever holds the bw session token.

For UIA/AT-SPI capture, walk the tree from the focused element up
one level and concatenate readable strings; suggest the longest
substring containing a URL or known token as the `text=` matcher.

### 10.1. Snapshot contents

The daemon's snapshot is a record with: `exe_path`, `exe_basename`,
window title, window class (or Wayland `resourceClass`),
focused-element role + IsPassword, plus a string built by walking
the focused element's ancestor for a short distance (used to
populate the URI's `text=` matcher).

### 10.2. When the snapshot is taken (no second hotkey press)

The user-facing UX is: *focus the target, press the capture hotkey,
the snapshot is of what was focused right then*. Implementation
differs per platform because Wayland forbids the daemon owning a
global hotkey:

**Linux (KDE Wayland)**

- The KDE custom shortcut `Ctrl+Shift+;` is bound to
	`vw-autofill add-interactive`.
- `add-interactive` is a tiny client. Step 1 of its lifetime is
	a synchronous IPC call to the daemon: "snapshot the foreground
	**now**." The daemon snapshots immediately and stashes the
	result in a pending-snapshot slot (random ID, 30-second TTL).
- Step 2: `add-interactive` spawns the user's terminal running
	`vw-autofill add --use-pending=<id>`, which retrieves the stashed
	snapshot and continues into the interactive prompts.
- No second hotkey press. The foreground at the moment the shortcut
	fires is the snapshot.

**Windows**

- The daemon owns the capture hotkey in-process via `RegisterHotKey`.
- On hotkey press the daemon snapshots foreground immediately, then
	spawns the terminal client with `--use-pending=<id>`.
- Same result, same no-second-press UX.

This works because in both cases the snapshot is captured **before**
any new window (terminal) opens that could steal focus.

---

## 11. Trigger flows

### Hotkey path

```
user presses fill hotkey
  → platform → daemon.onFillRequest()
  → resolve current foreground window: {exe, title, class}
  → resolve focused element: {role, isPassword}
  → match against rules with mode in {hotkey, auto} and platform allows current OS
  → if 1 match: apply cooldown; render sequence; type; record fire
  → if 0 matches: log + (optional) fall back to picker
  → if 2+ matches: log "ambiguous match: <names>"; do nothing
```

### Auto path

```
platform window-activation event
  → daemon.onWindowActivated({pid, caption, resourceClass})
  → resolve exe from pid
  → match against rules with mode == 'auto'
  → if match: enforce cooldown; re-verify foreground; type
  → else: ignore
```

Cooldown is keyed by `(uri, hwnd-or-windowId)` and lasts the URI's
`cooldown=` seconds (default from config `default_cooldown_s`, which
itself defaults to 15) to avoid retype storms on alt-tab cycling.

---

## 12. Platform plumbing

### Linux (KDE Plasma 6 Wayland)

**KWin script** (`kwin-script/contents/code/main.js`):

```javascript
workspace.windowActivated.connect(function (w) {
	if (!w) return;
	const payload = JSON.stringify({
		pid: w.pid,
		caption: w.caption,
		resourceClass: ('' + w.resourceClass),
	});
	callDBus(
		'org.user.VwAutofill', '/Daemon',
		'org.user.VwAutofill', 'WindowActivated',
		payload
	);
});
```

Installed via `kpackagetool6 -t KWin/Script -i kwin-script/` or by
dropping in `~/.local/share/kwin/scripts/`. Enabled via System
Settings → Window Management → KWin Scripts.

**Daemon side**:

- Registers D-Bus name `org.user.VwAutofill`, methods
	`WindowActivated`, `Fill`, `Capture`.
- Reads `/proc/<pid>/exe` symlink to resolve the exe path.
- AT-SPI: D-Bus calls to `org.a11y.atspi.Registry`. Get focused
	accessible, read `Role` (PASSWORD_TEXT = 7, TEXT = 9, ENTRY = 73),
	walk subtree for `uia_text_contains` matching. Hand-roll bindings
	for the handful of methods we use; AT-SPI's D-Bus surface is
	stable.

#### 12.1. Typing backends on Linux

The daemon abstracts typing behind a `LinuxTyper` interface with two
implementations, chosen per `typing_backend` in config (default
`portal`).

**Portal backend (default, no root)**:

- Talks to `org.freedesktop.portal.Desktop` over D-Bus.
- One-time setup: `CreateSession` on `RemoteDesktop` interface,
	`SelectDevices(keyboard)`, `Start` → user gets a KDE consent
	dialog the first time. The portal returns a restore token saved
	to `~/.config/vw-autofill/portal_restore_token` (mode 0600); next
	session reuses it.
- Typing: `NotifyKeyboardKeysym(session, options, keysym, state)`
	with `state=1` for press, `state=0` for release. Special keys use
	the X11 keysym table; characters use their unicode keysym.
- Same approach KeePassXC's PR #13359 uses; production-quality on
	KDE Plasma 6.3+.

**ydotool backend (fallback, opt-in)**:

- `osproc.startProcess('ydotool', ['type', '--', text])` for text
	and `ydotool key 15:1 15:0` for special keys.
- Requires `ydotoold` running and `/dev/uinput` writable by the user.
	The cleanest non-root setup: a udev rule (one-time admin) putting
	`/dev/uinput` in the `input` group, then add the user to `input`.
	After that the daemon runs unprivileged.
- Documented in README but not the default.

**Hotkey integration**:

- We do **not** register a global hotkey from the daemon. Instead the
	user binds a KDE custom shortcut to run `vw-autofill fill` (or
	`add`). The CLI client connects to the D-Bus name and calls the
	method. This sidesteps Wayland hotkey woes entirely and
	uses KDE's native shortcut manager.
- `vw-autofill enable-autostart` writes
	`~/.config/autostart/vw-autofill.desktop` and installs the KWin
	script package; prints exact instructions for the user to bind
	their hotkey in System Settings.

### Windows

**Daemon main thread**:

- Creates a hidden message-only window for hotkey + WinEvent dispatch.
- `SetWinEventHook(EVENT_SYSTEM_FOREGROUND, EVENT_SYSTEM_FOREGROUND,
	NULL, callback, 0, 0, WINEVENT_OUTOFCONTEXT)` — out-of-context so
	we avoid in-process injection into other apps.
- Callback enqueues to a Nim channel; main thread processes.

**Resolving the active window**:

- `GetWindowThreadProcessId(hwnd, &pid)`
- `OpenProcess(PROCESS_QUERY_LIMITED_INFORMATION, FALSE, pid)`
- `QueryFullProcessImageNameW(hProc, 0, buf, &size)`
- `GetWindowTextW(hwnd, buf, cap)`
- `GetClassNameW(hwnd, buf, cap)`

**Field-type detection (UIA)**:

```nim
# Pseudocode
let auto = CoCreateInstance(CLSID_CUIAutomation, ...).as(IUIAutomation)
var elem: IUIAutomationElement
auto.GetFocusedElement(&elem)
let controlType = elem.CurrentControlType  # e.g. UIA_EditControlTypeId
let isPassword = elem.GetCurrentPropertyValue(UIA_IsPasswordPropertyId)
```

Walk to parent and concatenate `CurrentName`/`CurrentHelpText` for
`uia_text_contains` substring matching.

**Typing (`SendInput`)**:

- For Unicode text: `KEYEVENTF_UNICODE`, one `INPUT` per UTF-16 code
	unit, paired down/up.
- For special keys (Tab, Enter, Shift+Tab): VK codes with
	`KEYEVENTF_KEYUP` toggle.
- Batch into a single `SendInput` call per token to reduce timing
	jitter.

**Hotkey**:

- `RegisterHotKey(NULL, HOTKEY_ID_FILL, MOD_CONTROL | MOD_ALT, 'B')`
- `RegisterHotKey(NULL, HOTKEY_ID_CAPTURE, MOD_CONTROL | MOD_SHIFT,
	VK_OEM_1)` (semicolon)
- Message loop dispatches `WM_HOTKEY`.

#### 12.2. UIPI / integrity-level injection failures

Windows User Interface Privilege Isolation (UIPI) blocks `SendInput`
from injecting keystrokes into a process running at **higher
integrity** than the source. A daemon running at **medium**
integrity (normal user) **cannot** type into a **high** integrity
target (anything launched elevated, or some system UIs). With no
admin we can't elevate the daemon, so this is a real failure mode
to surface clearly rather than fail silently.

Per-window diagnostic when a fill target is matched:

- `daemon_integrity` — read once on startup via
	`GetTokenInformation(TOKEN_INFORMATION_CLASS::TokenIntegrityLevel)`.
- `target_integrity` — `OpenProcessToken(target_pid, TOKEN_QUERY)` +
	same `GetTokenInformation` call. If access denied (common when
	target is higher integrity), report `unknown`.
- `can_inject` — derived: `yes` if `daemon_integrity ≥
	target_integrity`, `no` if strictly lower with known integrities,
	`unknown` otherwise.

Behavior:

- On fill attempt with `can_inject = no`: skip the type, log
	`"target is elevated, daemon cannot inject (UIPI); see
	vw-autofill doctor"`, and surface in `vw-autofill status` as
	the last-skip reason.
- On `can_inject = unknown`: try once; if `SendInput` returns 0,
	mark this hwnd's integrity as `high` for the rest of the daemon
	lifetime and don't retry.
- F5 Edge Client typically runs at medium integrity (user-launched),
	so this *shouldn't* bite for the main target, but it might for
	other apps and the user deserves a clear error.

---

## 13. Vault backend

```nim
type
	CustomField* = object
		name*: string
		value*: string
		fieldType*: int  # 0 text, 1 hidden, 2 boolean, 3 linked

	VaultItem* = object
		id*: string
		name*: string
		username*: string
		password*: string
		uris*: seq[string]
		fields*: seq[CustomField]

	VaultStatus* = enum
		vsUnauthenticated   # bw has no login
		vsLocked            # bw is logged in, session token absent or rejected
		vsUnlocked

	VaultBackend* = ref object of RootObj

method status*(b: VaultBackend): VaultStatus {.base.}
method setSessionToken*(b: VaultBackend, token: string) {.base.}
method getItems*(b: VaultBackend): seq[VaultItem] {.base.}
method getItem*(b: VaultBackend, id: string): VaultItem {.base.}
method updateItem*(b: VaultBackend, item: VaultItem) {.base.}
```

The interface has no `unlock(password)` and no other entry point
that accepts a master password — by design (see §13.1). The only
secret the daemon ever receives is a **session token** that `bw`
itself issued.

`BwBackend` shells out to `bw` / `bw.exe`. Resolution order is
**`bw_path` in config → PATH → daemon-binary directory**. The
session token is held in memory and persisted to a local file
(mode 0600, `O_NOFOLLOW`), or read from env if the user prefers
(`VW_AUTOFILL_SESSION_FROM_ENV=1`).

The interface makes mocking trivial — `FakeVault` (in `tests/harness/`)
implements all methods against an in-memory store.

### 13.1. Unlock UX — daemon never touches the master password

Hard rule: `vw-autofill` code paths must not read, prompt for, store,
forward, or otherwise handle the master password. Only `bw` ever sees
it (that's bw's job). The only credential the daemon holds is the
**bw-issued session token**.

Three unlock paths, in order of how the user reaches them:

**1. Manual (always available)**

In any terminal:

```
bw unlock --raw | vw-autofill unlock
```

`bw unlock --raw` prompts for the master password in that terminal,
validates it against the vault, prints the session token on stdout.
`vw-autofill unlock` reads stdin, calls `setSessionToken` on the
daemon over IPC. The password never enters a vw-autofill process.

**2. Interactive helper**

```
vw-autofill unlock-interactive
```

Spawns the user's preferred terminal emulator running the pipeline
from path 1. Terminal closes on success.

- Linux: tries `$TERMINAL`, then `konsole`, then `gnome-terminal`,
	then `alacritty`, then `xterm`.
- Windows: tries `wt.exe` (Windows Terminal), then falls back to
	`cmd.exe`.

The spawned terminal owns the password input; the daemon only sees
the token that comes back through the inner `vw-autofill unlock`
process's stdin.

**3. Notification-driven**

When the daemon hits locked state during a fill/capture (or on
startup with an expired session), it posts a desktop notification:

> vw-autofill: vault locked — click to unlock

Whose default action runs `vw-autofill unlock-interactive`. Linux
uses `org.freedesktop.Notifications` with `default-action`;
Windows uses a toast notification with an activation handler.

**4. Startup behavior**

On daemon start:

1. Read `session_token_path` (mode 0600). If present, call
	`setSessionToken` and probe `status()`.
2. If `vsUnlocked`, ready.
3. If `vsLocked` or `vsUnauthenticated`: post the notification
	(path 3) and wait. The daemon does **not** prompt anything itself.
4. Fills and captures requested before unlock log "vault locked,
	skipping" and re-post the notification (debounced).

Security properties:

- The vw-autofill binary's own argv, env, stdin handlers, and code
	never accept a password.
- Session token file is created with `O_NOFOLLOW` + mode `0600`,
	and is the only persistent secret the daemon writes.
- When `bw` expires the session, behavior cleanly degrades to path 3.

Trade-off acknowledgment: this is one extra step every time the
session token expires (typically once per day with default `bw`
timeouts). Users who want zero-touch unlock can configure `bw` to
hold its session longer, or use a system keyring integration in `bw`
itself — but that's bw's territory, not ours.

### 13.2. `updateItem` pipeline (`bw encode` required)

`bw edit item <id>` expects the new JSON body **base64-encoded** via
`bw encode`, not as raw JSON on stdin. Skipping `bw encode` is a
common mistake that silently fails or produces malformed items.
`BwBackend.updateItem` must use exactly:

```
1. bw get item <id> --session <token>     → JSON
2. modify JSON in memory:
   - append, replace, or remove a URI on .login.uris
   - (.fields untouched — behavior lives in the URI's query params)
3. echo <new-json> | bw encode             → base64
4. bw edit item <id> --session <token>     ← reads base64 from stdin
```

Implementation does steps 3 and 4 in one `osproc` pipeline so the
JSON never touches the filesystem.

Integration test (Slice 2): create a real test login item via
`bw create item`, exercise `updateItem` end-to-end against a real
`bw` against a disposable Vaultwarden test account / local server,
re-fetch, assert the new URI is present in `.login.uris` with the
expected query params. This catches `bw encode` regressions and
JSON-shape drift that pure fixtures wouldn't.

---

## 14. Config

Local config at:

- Linux: `~/.config/vw-autofill/config.yaml`
- Windows: `%APPDATA%\vw-autofill\config.yaml`

```yaml
bw_path:               # optional; if empty, PATH then daemon-binary dir
session_token_path: ~/.config/vw-autofill/session
portal_restore_token_path: ~/.config/vw-autofill/portal_restore_token
log_level: info

typing_backend: portal         # portal | ydotool (Linux only)
hotkey_fill: ctrl+alt+b        # Windows only; on Linux bind via KDE
hotkey_capture: ctrl+shift+';'
ydotool_path: /usr/bin/ydotool # Linux only, used if typing_backend=ydotool
fallback_picker: false         # show picker on no-match
default_cooldown_s: 15
default_sequence: '$user$tab$pass$enter'
```

YAML is the on-disk format. The loader uses
`nyml` (<https://github.com/openpeeps/nyml>); missing keys fall back
to compiled-in defaults, unknown keys produce a warning (not an
error) so users can keep old configs through schema evolution.

All config is **local in v1**. The only thing that syncs through
Vaultwarden are the rules — URIs on each login item, query params
and all. A vault-side config overlay was considered and cut for v1
(see §22); too much config-merging / sync-semantics surface area
before the core app is solid.

---

## 15. Safety controls

These are non-negotiable defaults baked into the rule loader and
trigger logic:

1. Reject title-only rules unless `--unsafe` flag was passed to the
	add command. Window titles are app-settable (phishing vector); exe
	path is not.
2. Re-verify foreground window in the ~50 ms before typing; abort if
	it changed.
3. Per-rule cooldown (default 15 s) keyed by rule + window.
4. `auto` mode is opt-in per rule. Default new rule mode is `hotkey`.
5. If `autofill.field_check = password` is set, refuse to type until
	the focused element is reported as a password field. (UIA on
	Trident — F5 — is mediocre, so we default `field_check` empty for
	F5 and rely on exe+title.)
6. Daemon never logs the typed values, only the rule name + timing.
7. No autostart by default. User explicitly opts in with
	`enable-autostart`.

---

## 15a. `vw-autofill doctor`

Self-diagnostic subcommand that runs end-to-end environment checks and
emits a clear pass / warn / fail line for each. The intent: when
something doesn't work, this saves an hour of digging.

Common checks:

| Check | Pass condition |
|---|---|
| `bw` resolves | `bw_path` → PATH → daemon dir finds an executable |
| `bw` is recent enough | `bw --version` ≥ minimum required |
| `bw` logged in | `bw status` reports `locked` or `unlocked` (not `unauthenticated`) |
| `bw` unlocked | session token works against `bw status` |
| daemon running | IPC ping succeeds |
| IPC reachable | D-Bus name acquired / named pipe writable |
| rules loaded | non-zero parsed rules, with skipped-rule count |

Linux-only:

| Check | Pass condition |
|---|---|
| KDE Plasma 6 session | `$XDG_CURRENT_DESKTOP=KDE` and Plasma ≥ 6.3 |
| KWin script installed | file present under `~/.local/share/kwin/scripts/vw-autofill/` |
| KWin script enabled | `kreadconfig6 --group Plugins --key vw-autofillEnabled true` |
| Portal available | `org.freedesktop.portal.RemoteDesktop` D-Bus name present |
| Portal keyboard allowed | a stored restore token validates, or first-run prompt is available |
| AT-SPI reachable | `org.a11y.Bus` D-Bus name present |
| ydotool reachable (if selected) | `ydotool --version` returns; `/dev/uinput` writable |

Windows-only:

| Check | Pass condition |
|---|---|
| Named pipe reachable | `\\.\pipe\vw-autofill` connectable from client |
| Hotkeys registered | `RegisterHotKey` for fill+capture returned success |
| `daemon_integrity` | medium (expected for no-admin) |
| UIA available | `CoCreateInstance(CLSID_CUIAutomation)` succeeds |
| Test target injectability | optional: type into Notepad's edit control and assert |

Output: one line per check, color-coded. Exit code 0 if all pass,
non-zero if any fail. Intended to be run by the user after every
platform change (KDE update, Windows feature update, etc.) and on
first install.

---

## 16. Logging

- Linux: stderr by default; `systemd --user` unit prints to journal
	if user runs that way. File log opt-in.
- Windows: file log at `%LOCALAPPDATA%\vw-autofill\log\daemon.log`,
	rotated at 1 MB, keep 3.
- Format: `[YYYY-MM-DD HH:MM:SS] LEVEL component: message`. No
	secrets ever. Rule name, window class, exe path, decision (fire /
	skip / ambiguous), cooldown remaining.

---

## 17. AV mitigations (Windows)

- Build flags: `-d:release --opt:speed`, **not** `-d:danger`, **not**
	`--opt:size`. Avoid stripping symbols.
- Target binary size: aim for ~500 KB – 1.5 MB. If Nim release is
	under ~150 KB, that's actually a heuristic red flag for some
	engines; consider linking in a small static resource (icon + dummy
	strings table) to bump the size, but don't go overboard.
- Embed:
	- `manifest.xml` declaring `<requestedExecutionLevel
		level='asInvoker' uiAccess='false'/>`
	- Full version info: CompanyName=`vw-autofill`,
		FileDescription=`Vaultwarden Autofill Daemon`,
		ProductName=`vw-autofill`, OriginalFilename=`vw-autofill.exe`,
		LegalCopyright=`<user>`, FileVersion, ProductVersion.
	- Icon.
- No UPX, no obfuscation.
- Don't bundle `bw.exe` — user places it.
- Use `SetWinEventHook` (out-of-context) — much less suspicious than
	`SetWindowsHookEx(WH_KEYBOARD_LL)`.
- No autostart on first run; explicit `enable-autostart` opt-in
	writes only `HKCU\…\Run`.

If Defender flags it on first run despite the above: submit to
<https://www.microsoft.com/en-us/wdsi/filesubmission>; typical
turnaround is a few days. Per-user-scoped exclusion is the immediate
workaround (may or may not be available under school MDM).

---

## 18. Testing

Comprehensive auto-tests are a non-negotiable deliverable. Every
module ships with tests that exercise the happy path, every documented
failure mode, and platform-specific edge cases via fakes. Manual tests
fill in only where the OS event surface genuinely can't be reasonably
mocked (real keystroke injection into real apps, real KWin events,
real Defender response).

### 18.1. Test categories

**Unit tests** — per-module, fast, no I/O, no real OS APIs.

- `test_rules`: parse 30+ field-combination fixtures; reject invalid
	regex; reject title-only without `--unsafe`; defaults; platform
	filter; round-trip from object → custom-field set → object.
- `test_seq_template`: tokenize, render, escape `{{`/`}}`, unknown
	tokens, delays, custom-field lookup, empty seq, trailing brace,
	unicode passwords.
- `test_vault_parse`: 20+ shapes of `bw get items` JSON (committed
	snapshots), missing fields, deleted items, items with no login
	object, items with malformed URI schemes / query attrs.
- `test_match`: every documented match dimension and combination
	(exe-only, exe+title regex, exe+class, exe+class+text), positives
	and negatives, OS-platform filter, case-insensitive exe on
	Windows.
- `test_capture`: scripted stdin driving the wizard; fake platform
	produces fake snapshot data; assert resulting `bw edit` payload
	matches expected JSON.

**Integration tests** — driven through fakes, run anywhere (CI on
Linux covers both target builds).

Three injected interfaces let the whole daemon run in a test process
with no real OS surface:

- `FakeVault` — in-memory `VaultBackend`. Tests assert on the writes
	the daemon makes.
- `FakePlatform` — synthesizes window-activation events, supplies
	focused-element state, records keystrokes the daemon emits.
- `FakeBus` — synchronous in-process message passing.

End-to-end integration cases (each is a single test function):

- **Hotkey fill, unique match**: scripted fill hotkey → assert
	correct sequence typed into `FakePlatform`.
- **Hotkey fill, no match**: scripted hotkey on irrelevant window →
	assert nothing typed, log line emitted.
- **Hotkey fill, ambiguous**: two rules match → assert no typing,
	specific log line.
- **Auto fire**: synthetic window-activation event matching `auto`
	rule → assert sequence typed.
- **Auto fire cooldown**: two consecutive activations within cooldown
	→ assert only one fire.
- **Foreground race**: between event and type, fake foreground
	changes → assert abort.
- **Field-check gate**: `field_check=password` with non-password
	focused element → assert no typing.
- **Capture round-trip**: scripted user input + fake snapshot → assert
	exact URI and `autofill.*` field set written to fake vault.
- **Vault locked at startup**: assert prompt path; supply password
	via test stdin; assert successful unlock.
- **bw stderr error path**: fake bw binary that exits 1 → assert
	clean daemon-side error, no crash.

**Property tests** (using deterministic seeding):

- Sequence template: `tokenize ∘ render` ≈ identity modulo
	escape-unification. Generate random sequences, run round-trip.
- Rule round-trip: arbitrary `Rule` → custom-field set → `Rule`,
	assert equal.

**Platform smoke tests** (gated, opt-in, run manually or in
platform-specific CI):

Other languages are fair game for the smoke-test apps — they're test
fixtures, not part of the shipped daemon. Python is the path of least
resistance.

- **Linux test target**: small Python + PyQt6 app `tests/smoke/target_linux.py`
	with a `QLineEdit` (username) and `QLineEdit(echoMode=Password)`
	(password). The app writes every change to a JSON log file on
	disk. Qt exports AT-SPI automatically. Test harness: launch the
	app, focus a field, send the daemon a `fill` request via D-Bus,
	wait for the log file to update, assert it contains the expected
	username and password. Requires display server — runs on the dev
	machine, not in headless CI.
- **Windows test target**: Python + tkinter app
	`tests/smoke/target_windows.py` with the same two-field layout
	and JSON log. tkinter uses Win32 `Edit` controls so UIA sees them
	cleanly. Same test harness pattern. Manual or runs under a GUI
	Windows CI runner.
- **HTTP-Basic-auth simulator**: `tests/smoke/basic_auth_server.py`
	— Python stdlib `http.server` returning `401 WWW-Authenticate:
	Basic` and logging the credentials it receives. The user (or
	test harness) points Firefox at `localhost:8080`, the browser
	pops its native auth dialog, daemon fills, server logs the
	creds, harness asserts.

**Build tests**:

- `tools/check.sh`:
	1. `nim check src/...` on every module.
	2. `nimble test` runs all unit + integration tests.
	3. Linux native build.
	4. Windows cross build via MinGW (build-only verification; no
		execution).
	5. PE binary size check (warn if outside 300 KB – 2 MB).
	6. Smoke-run `./build/vw-autofill --version` (Linux only).

Exit non-zero if any step fails.

**Real-`bw` integration test** (Slice 2 deliverable):

- Test fixture spins up a disposable Vaultwarden instance (Docker)
	or uses a dedicated test account.
- `BwBackend.updateItem` round-trip: create item → updateItem with
	a new URI on `.login.uris` and `autofill.*` field changes →
	re-fetch → assert round-trip equality.
- Covers the `bw encode` pipeline (see §13.2) which fixtures alone
	cannot catch.

**No Wine**:

Wine does not reliably reproduce UIA / `SendInput` behavior, and
faked-Win32-on-Linux results cannot substitute for real Windows
verification. All Windows-platform tests run on a **real Windows
machine** — manual on the user's laptop, or on a dedicated Windows
runner if/when CI grows. Cross-build verification (compilation
succeeds, PE shape sane) runs on Linux without execution.

### 18.2. Mocking strategy

The daemon's main loop is a single function that takes `VaultBackend`,
`Platform`, and `Bus` as parameters. Tests instantiate the daemon with
the fake trio and drive it; the real entry point in `vwautofill.nim`
just wires up the real implementations. This means every code path
except the platform glue itself runs in unit/integration tests on the
build host.

### 18.3. Coverage target

- Unit tests: ≥ 90% line coverage on `rules.nim`, `seq_template.nim`,
	`match.nim`, `capture.nim`, `vault.nim` (parsing/serialization
	half only).
- Integration tests: every CLI subcommand exercises its happy path
	and at least one documented failure path.
- Coverage measured via `nim --debugger:native -d:coverage` + lcov
	(Linux only). `tools/check.sh` runs it and emits a summary.
- CI gate at 85% overall.

### 18.4. CI

Local-only initially (`tools/check.sh` is the single command). If/when
pushed to a remote, a tiny GitHub Actions workflow:

- Linux job: full unit + integration tests, coverage, native build,
	Windows cross-build (compile-only).
- Windows job (real Windows runner, optional): runs Windows-gated
	platform smoke tests against a real Windows environment. **No
	Wine** — see §18.1.

### 18.5. Test discipline

- Every PR / commit that adds a feature also adds tests for it.
- Every bug fix adds a regression test that fails before the fix.
- No skipped/disabled tests committed; if a test can't run on a
	platform, it's gated at the test level with a clear reason, not
	commented out.
- Tests use real fixtures (`tests/fixtures/*.json` are committed real
	`bw get items` outputs scrubbed of secrets) rather than hand-rolled
	dictionaries — keeps them honest against `bw` output drift.

---

## 19. Implementation order

Reordered to **front-load platform proof** — the riskiest parts (KDE
Wayland portal, AT-SPI, Windows UIA / SendInput, Windows UIPI) get
proven in throwaway demos before any real code depends on them.

Each slice is independently usable / testable. **Each slice ships its
own auto-tests** — no slice is "done" until the relevant tests are
green via `tools/check.sh`. Don't move on until the previous slice's
success criteria pass.

### Slice 0 — Platform proof (Linux first, throwaway demos)

Goal: prove the risky Linux platform paths work *before* writing any
Nim that depends on them. **Do Linux first**; do not touch Bitwarden
or Windows until all three Linux demos pass on the user's actual
KDE session. The Windows demo gets its own block after the Linux
work is real.

Each demo is a tiny standalone program under `tools/proof/<name>/`,
allowed to be ugly, deleted or kept as reference once the
corresponding real implementation lands.

**Linux block (do these first, in this order):**

1. **Portal typing demo** (`tools/proof/portal-type/`): opens a
	RemoteDesktop portal session, stores the restore token, types
	"hello world" into KCalc. Confirms KDE Plasma 6.3+ portal flow
	and that the restore-token mechanism actually persists. If this
	fails on the user's KDE, the default typing backend has to
	switch to `ydotool` and the failure mode is recorded.
2. **AT-SPI focus demo** (`tools/proof/atspi-focus/`): hooks AT-SPI
	focus events, prints `role` (text / password / etc.) when focus
	changes inside a Qt or GTK app. Confirms role detection is
	usable for the `field_check` gate.
3. **KWin window-activated demo** (`tools/proof/kwin-event/`): a
	KWin script that emits `pid` / `caption` / `resourceClass` via
	D-Bus on every window activation. A small Nim/Python listener
	on the other end prints what it received. Demonstrates the
	pipeline shape that Slice 3 will use.

Done (Linux block): all three demos pass on the user's KDE laptop.
Failure of any one is a stop-and-redesign moment, not a "move on
anyway" moment.

**Windows block (only after the Linux block passes):**

4. **Windows SendInput demo** (`tools/proof/win-sendinput/`): cross
	the bridge to Windows once — minimal C/Nim program that uses
	`SetWinEventHook` + `SendInput` to type into Notepad, plus the
	UIPI-integrity probe described in §12.2. Run on the user's
	actual Windows laptop without admin. If this fails because of
	enterprise endpoint protection or any other school-laptop
	specific issue, that's the moment we know — before sinking
	days into Slice 7.

Done when: all four demos work on the user's actual machines.

### Slice 1 — Rule schema + sequence template

Files: `rules.nim`, `seq_template.nim`, `match.nim`, `config.nim`,
`log.nim`.

Goal: pure-Nim core. Parse URIs (`winapp://` / `linapp://` /
`app://` with all query attrs) and `autofill.*` custom fields into
in-memory `Rule` records, match against synthetic window state,
render sequence templates. Zero I/O dependencies.

Tests delivered: `test_rules` (URI parse: 30+ shapes including
full-path, basename, query-only, malformed; behavior-field defaults;
auto-mode strictness — every URI must have an extra matcher),
`test_match` (every match dimension, OS filter, case-insensitive exe
on Windows), `test_seq_template` (tokenize/render/escape/unicode),
property tests for both (URI parse ↔ unparse round-trip;
tokenize ∘ render ≈ id).

Done when: all Slice 1 tests green at ≥ 90% line coverage on these
modules.

### Slice 2 — `bw` backend with real edit round-trip

Files: `vault.nim` (`BwBackend`), `test_vault_parse.nim`,
`tests/integration/test_bw_roundtrip.nim`.

Goal: implement `VaultBackend` against a real `bw`. The
`updateItem` path goes through the proper pipeline: `bw get item` →
modify JSON → `bw encode` → `bw edit item` (see §13.2).

Tests delivered:

- `test_vault_parse` against committed `bw get items` snapshots.
- Real round-trip integration test: spin up a Vaultwarden test
	instance (Docker compose under `tests/integration/`), `bw login`
	against it from CI / dev, create-modify-fetch-assert.

Done when: `vw-autofill list` against a real unlocked vault enumerates
test rules; integration round-trip green; `bw encode` is exercised on
every write.

### Slice 3 — Linux daemon (D-Bus + KWin + portal + AT-SPI)

Files: `platform_linux.nim`, `bus_linux.nim`,
`kwin-script/contents/code/main.js`,
`tests/harness/fake_platform.nim`, `tests/harness/fake_bus.nim`.

Goal: real KWin script sends `WindowActivated` events to daemon over
D-Bus; daemon resolves exe path from `/proc/<pid>/exe`; portal
RemoteDesktop typer with consent flow and restore-token caching;
ydotool typer as the configured fallback; AT-SPI focused-element
read.

Tests delivered: `test_bus_linux`, `test_platform_linux` against
`FakePlatform`, the first integration test driving the whole daemon
end-to-end with fake event sources.

Done when: daemon prints active window's exe + title + focused-role on
every window change against the running KWin script; portal typing
demonstrably works against KCalc; Slice 3 tests green.

### Slice 4 — Linux hotkey + fill flow

Files: `bus.nim`, `vwautofill.nim` (`fill` subcommand), expand
`test_integration.nim`.

Goal: `vw-autofill fill` connects to the daemon and asks it to apply
rules to the current foreground. KDE custom shortcut wires this up.

Tests delivered: integration tests for every hotkey-fill case (unique
match, no match, ambiguous, cooldown, foreground race, field-check
gate, auto-mode strictness gate).

Done when: bind a KDE shortcut to `vw-autofill fill`, focus a test
app, press hotkey, rule fires or is rejected with a clear log line;
Slice 4 tests green.

### Slice 5 — Capture / add flow (client-owned prompts)

Files: `capture.nim`, `vwautofill.nim` (`add`, `add-interactive`,
`edit`, `delete`), `test_capture.nim`.

Goal: capture flow as described in §10. Client process owns the
prompts; daemon owns the snapshot and the vault writeback. New rules
are added as additional URIs on the chosen vault item (sharing one
credential and one set of behavior settings); existing URIs / field
values can be edited or deleted interactively.

Tests delivered: `test_capture` (scripted stdin in the client, fake
snapshot from daemon, asserts on the JSON written to `FakeVault`);
integration test covering an end-to-end add → fire cycle.

Done when: a brand-new rule can be created in one session and
immediately fires on the next hotkey press; multi-rule items work;
Slice 5 tests green.

### Slice 6 — Linux smoke + user validation

Goal: repeatable automated smoke test against a Python target app,
plus user-driven validation against real targets.

Tests delivered:

- `tests/smoke/target_linux.py` (PyQt6) + `tests/smoke/run_smoke.sh`
	— bring up the target, drive the daemon, assert log contents.
- `tests/smoke/basic_auth_server.py` for the HTTP-Basic dialog path
	(user-driven; can't fully automate Firefox cleanly).
- Regression fixtures for quirks found in real Firefox dialog (and
	any other targets the user surfaces).

Done when: PyQt6 target fills correctly via both `hotkey` and
`auto` modes from the smoke script; cotauth.toronto.ca login fills
with a single hotkey press; `vw-autofill doctor` passes on the
user's KDE laptop.

### Slice 7 — Windows platform

Files: `platform_windows.nim`, `platform_windows_uia.nim`,
`bus_windows.nim`, `test_bus_windows.nim`, `test_platform_windows.nim`.

Goal: `SetWinEventHook` listener; hwnd → exe; UIA focused-element
role + IsPassword; `SendInput` typer with UIPI integrity probe;
`RegisterHotKey` for fill + capture; named-pipe IPC.

Tests delivered: same suite as Slices 3–5 but on Windows. **Run on a
real Windows machine** — Wine is not used.

Done when: same demos as Linux work on Windows; UIPI integrity probe
correctly reports `daemon_integrity` and `target_integrity`; Slice 7
tests green on real Windows.

### Slice 8 — Cross-compile + packaging

Files: `nim-mingw.cfg`, `packaging/windows/*`, `tools/build-windows.sh`,
`tools/check.sh`.

Goal: `make windows` from Linux produces a clean `vw-autofill.exe`
with embedded manifest, version info, icon. `tools/check.sh` runs
the full build + test pipeline cleanly on Linux (Windows test suite
runs separately on a real Windows host). Local Defender scan after
transferring to Windows; iterate if flagged.

Tests delivered: `tools/check.sh` exits 0 from a clean checkout;
PE size check; smoke `--version` run.

Done when: built exe runs on Windows without admin and Defender
leaves it alone.

### Slice 9 — Windows smoke + user validation

Goal: user tests against F5 client + Firefox HTTP-auth dialog on
Windows laptop.

Tests delivered:

- `tests/smoke/target_windows.py` (tkinter) + parallel `run_smoke.sh`
	(or `run_smoke.cmd`).
- Regression fixtures for any Windows-specific quirks discovered.

Done when: the flows that work on Linux work on Windows; F5 client
fills with a single hotkey press; `vw-autofill doctor` passes on the
user's Windows laptop.

---

## 20. Open questions

1. F5 Edge Client version (user to fetch).
2. F5 login flow: F5-branded form vs SSO IdP redirect (user to
	observe).
3. Whether to ship Slice 5 user-validation before starting Slice 6,
	or interleave.
4. D-Bus binding choice: hand-roll vs nim-dbus package. Decide at
	start of Slice 2.

---

## 21. Risk register

| Risk | Likelihood | Mitigation |
|---|---|---|
| Defender flags the Nim binary | medium | §17; submit to MS if hit; per-user exclusion fallback |
| UIA on Trident (F5) underreports field types | high | Don't gate F5 rule on `field_check`; rely on exe + title |
| Input emulation hits wrong window due to focus race | medium | Re-verify foreground in ~50 ms before typing (§15.2); applies to portal and ydotool equally |
| KWin scripts API drift between Plasma 6 minors | low | Pin to `workspace.windowActivated` which is stable; tested on 6.6 |
| `xdg-desktop-portal-kde` not installed or older than 6.3 | medium | Detect at start; degrade to `ydotool` backend with a clear log line; document the fallback |
| AT-SPI not available on user's KDE | low | Detect at start; warn; degrade by disabling `field_check` |
| User can't find a terminal to run unlock pipeline | low | `unlock-interactive` tries multiple terminal emulators; manual pipeline works in any terminal; notification action keeps the door open |
| Vaultwarden + custom-fields edits clobbering each other | low | Always read-then-write the full item; never PATCH partial |
| Windows UIPI blocks injection into elevated target | medium | §12.2 integrity probe; `vw-autofill doctor` and `status` surface the failure clearly instead of silent dropping |
| `bw edit` malformed (missing `bw encode`) | medium | §13.2 pipeline is the only write path; Slice 2 round-trip test catches regressions |
| Tests drift from real `bw` JSON shape | medium | Fixtures are real scrubbed `bw` outputs + Slice 2 real-bw round-trip test; refresh on `bw` major version bumps |

---

## 22. Future features (v1.1+)

Deliberately deferred, kept here so they don't get forgotten.

### Secure-note settings sync

A Bitwarden secure note named `vw-autofill.config` whose YAML body
overlays the local config for *behavior* keys (sequence default,
cooldown default, hotkeys, fallback_picker, etc.). Bootstrap keys
(`bw_path`, `session_token_path`, `portal_restore_token_path`,
`log_level`) stay local to avoid chicken-and-egg with `bw` resolution
and unlock.

Cut from v1 to keep the surface small: it adds config merging, sync
semantics, reload behavior, and a few new failure modes that don't
exist today. Once the core app is solid, this is a clean addition —
the daemon already syncs from the vault on `bw sync`, so wiring up a
note read on top of that is a small change.

### TOTP autofill

Add `{TOTP}` to the sequence template, wired through `bw get totp
<id>`. The token is already defined in §9 as v1.1; the work is
mostly just plumbing.

### Other targets

- **macOS** — `CGEventPost` for typing, NSAccessibility for field
	detection, `org.bitwarden.cli` install on PATH. Same architecture.
- **X11 / XWayland on Linux** — `XTestFakeKeyEvent` typing,
	`XQueryTree` window inspection. The existing platform abstraction
	already separates this cleanly; mostly drop-in.
- **Wayland compositors other than KWin** — wlroots-based (sway,
	Hyprland) using `wlr-foreign-toplevel-management` instead of the
	KWin script. Same daemon, swap the window-source.

### Note from v1

These were considered for v1 and pushed out for one of three reasons:
not strictly needed for the F5 + cotauth use case (TOTP, GUI);
adds disproportionate complexity before the core works (secure-note
overlay); or scope-creep into new platforms (macOS, other
compositors, X11). Bring them back one at a time after v1 is in
real use.
