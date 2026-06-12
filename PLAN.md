# vaultwarden-autofill — Plan (Option B: Nim everywhere)

Cross-platform desktop autofill daemon, single Nim codebase, backed by
Bitwarden/Vaultwarden via `bw` CLI. Targets Linux (KDE Plasma 6 Wayland)
and Windows (no admin), built from Linux via MinGW cross-compilation.

Option A (AHK on Windows) is held back in case school IT blocks AHK;
swapping in would replace Slices 7–9 only.

## Current status (rolling)

**Linux core: functional end-to-end as of 2026-06-12.**
Capture → daemon → KWin shortcut → match → ydotool type works against a
live Vaultwarden. Remaining Linux items are polish (edit/delete
subcommands, doctor, AT-SPI), and the portal typer (deferred because
the user's session denies it). Windows slices not started. Slice-level
done/partial/deferred markers are inline in §19.

---

## 1. Scope

**In for v1**

- Linux: KDE Plasma 6 Wayland. KWin script for window activation;
	`xdg-desktop-portal` RemoteDesktop typing (default, user-mode) with
	`ydotool` fallback; AT-SPI for field-type detection.
- Windows (no admin): `SetWinEventHook`, `SendInput`, UIA COM,
	`RegisterHotKey`.
- Vault: `bw` CLI on both, behind a `VaultBackend` interface (so `rbw`
	can swap in on Linux later).
- Rule storage: **everything in URIs** on the login item's
	`.login.uris` — `winapp://` / `linapp://` / `app://` schemes,
	matchers (`title`, `title_regex`, `class`, `text`) and behavior
	(`mode`, `sequence`, `cooldown`, `field_check`, `unsafe`) all as
	URI query params. No custom fields. Extends bitwarden-autotype's
	convention; many URIs per item = one credential across many
	windows, each URI carrying its own behavior (see §8).
- Capture-driven CLI to add / edit URIs (no GUI).
- Two trigger modes **per URI**: `hotkey` (default), `auto` (opt-in,
	used for F5).

**Out for v1**: TOTP, GUI editor, macOS, non-KWin Wayland, X11 on
Linux, installer/MSI. Distribution = portable folder.

---

## 2. Locked-in decisions

Shared: Nim (release, no UPX, no `-d:danger`); `VaultBackend`
interface with `bw` impl, resolved via `bw_path` → PATH → daemon dir;
local YAML config via `nyml`; rules in URIs on `.login.uris` (matchers
and behavior as query params, see §8); daemon never touches the
master password — user runs `bw unlock --raw | vw-autofill unlock`,
notification + helper spawn a terminal running that pipeline.

| Area | Linux | Windows |
|---|---|---|
| Build | Native (Nim + gcc) | Cross-compiled via `mingw-w64`; `windres` for resources |
| Hotkey | KDE custom shortcut → `vw-autofill fill` → IPC | `RegisterHotKey` in-process; defaults `Ctrl+Alt+B` / `Ctrl+Shift+;` |
| Typing | `xdg-desktop-portal` RemoteDesktop (default); `ydotool` opt-in fallback | `SendInput` with `KEYEVENTF_UNICODE` |
| Window detect | KWin script → D-Bus with `pid`/`caption`/`resourceClass` | `SetWinEventHook(EVENT_SYSTEM_FOREGROUND, …, WINEVENT_OUTOFCONTEXT)` |
| Field detect | AT-SPI over D-Bus (Qt/GTK/Firefox) | UIA COM (`IUIAutomation`); covers Trident/WebView2/CEF/Electron |
| IPC | D-Bus session bus, `org.user.VwAutofill` / `/Daemon` | Named pipe `\\.\pipe\vw-autofill` |
| Privilege | User-mode with portal; ydotool needs `input` group (one-time admin udev rule) | No admin |
| AV posture | n/a | Unsigned; embedded manifest + version info + icon; ~500 KB–1.5 MB |
| Smoke target | PyQt6 two-field app + JSON log | tkinter two-field app + JSON log |

---

## 3. Architecture overview

Single Nim binary `vw-autofill` with subcommands:

```
vw-autofill daemon              # [DONE] long-running. If BW_SESSION env is unset, runs `bw unlock --raw`
                                #        with the prompt routed to /dev/tty so the user can type the master
                                #        password without env wiring. YDOTOOL_SOCKET / VW_AUTOFILL_LOG default
                                #        sensibly. Warns up front if ydotoold socket is missing.
vw-autofill fill                # [DONE] one-shot: signal daemon to fill now
vw-autofill unlock              # [TODO] read session token from stdin, hand to daemon
vw-autofill unlock-interactive  # [TODO] spawn terminal running 'bw unlock --raw | vw-autofill unlock'
vw-autofill capture             # [DONE] interactive add flow (also subsumes the planned 'add-interactive';
                                #        edit / delete dropped from scope — vault items are editable in the
                                #        Bitwarden web UI, no need to re-implement that here)
vw-autofill list                # [DONE] list configured rules
vw-autofill status              # [DONE] partial: prints bw status JSON; daemon health/last-fire still pending
vw-autofill reload              # [DONE-NEW] tell daemon to refetch rules from bw (not originally in this list)
vw-autofill introspect          # [DONE-NEW] fetch daemon's introspection XML
vw-autofill simulate ...        # [DONE-NEW] synthesize WindowActivated D-Bus call
vw-autofill snapshot            # [TODO] print current foreground snapshot (debug)
vw-autofill match               # [TODO] print which rules would match the foreground
vw-autofill doctor              # [TODO] environment self-check, see §15a
vw-autofill enable-autostart    # [TODO]
vw-autofill disable-autostart   # [TODO]
vw-autofill install-kwin-script    # [TODO] (Linux only; today done by kpackagetool6)
vw-autofill uninstall-kwin-script  # [TODO]
```

`daemon` is the long-running process; every other subcommand is a
client that talks to it via local IPC. The daemon **never owns a
terminal** — interactive prompts run in the client (any terminal, or
one spawned by the `-interactive` variants).

The debug pair (`snapshot`, `match`) prints the daemon's view of the
foreground without typing — the first thing to reach for when
something doesn't fire. (`fill --dry-run` was dropped; the daemon log
already shows match decisions, and `simulate` covers the "what would
match" case from the other direction.)

**IPC** wrapped behind a `Bus` interface:

- Linux: [DONE] D-Bus session bus. Actual name is `org.vwautofill.Daemon`,
  path `/org/vwautofill/Daemon`, interface `org.vwautofill.Daemon1`.
- Windows: [TODO] named pipe `\\.\pipe\vw-autofill`.

---

## 4. User experience

### 4.1. First-time setup (~5 minutes)

1. Drop `vw-autofill` / `vw-autofill.exe` somewhere writable
	(`~/.local/bin/`, `%LOCALAPPDATA%\Programs\vw-autofill\`).
2. Make `bw` reachable: PATH, or next to the binary, or pin with
	`bw_path:` in config (config wins).
3. `bw config server https://your.vaultwarden.host && bw login`.
4. Linux only: `vw-autofill install-kwin-script` then enable in
	System Settings → KWin Scripts. On first fill, KDE prompts to
	allow keyboard/mouse control — tick "Remember" and approve; the
	portal restore token is cached in the config dir. For ydotool
	instead, see §12.1.
5. Bind hotkeys:
	- Linux: KDE Custom Shortcuts → `Ctrl+Alt+B` runs `vw-autofill
		fill`, `Ctrl+Shift+;` runs `vw-autofill add-interactive`.
	- Windows: daemon registers from `config.yaml` defaults.
6. `vw-autofill enable-autostart` — systemd `--user` unit if
	available, else `~/.config/autostart/*.desktop`; Windows writes
	`HKCU\…\Run`.
7. `vw-autofill daemon`. On first run, vault is locked → desktop
	notification → click to spawn a terminal running the unlock
	pipeline. See §13.1.
8. Manual unlock anytime: `bw unlock --raw | vw-autofill unlock`.

### 4.2. Daemon startup behavior

```
$ vw-autofill daemon
[14:02:11] INFO daemon: loading config from ~/.config/vw-autofill/config.yaml
[14:02:11] INFO vault: bw status: unlocked (cached session)
[14:02:12] INFO rules: loaded 3 rules from 47 vault items
[14:02:12] INFO bus: D-Bus name acquired: org.user.VwAutofill
[14:02:12] INFO daemon: ready
```

If locked, the daemon posts an unlock notification (§13.1) and waits.

### 4.3. Adding your first rule — F5 BIG-IP Edge Client

UX: focus the target, press capture hotkey, snapshot is of *that*
foreground, then a terminal opens for prompts (no second hotkey).

1. Focus the F5 login window's username field.
2. Press `Ctrl+Shift+;`. Daemon snapshots immediately, then spawns a
	terminal running `vw-autofill add --use-pending=<id>`.
3. In the spawned terminal:

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

4. The 'School VPN' item now carries one extra URI on
	`.login.uris`. Additional windows for the same credential = more
	URIs on the same item (see §8.2).

### 4.4. Daily use — hotkey path (browser HTTP-auth)

Browser HTTP Basic dialog appears (e.g. cotauth.toronto.ca) →
`Ctrl+Alt+B` → daemon matches on `firefox` + `MozillaDialogClass` +
text `cotauth.toronto.ca` → types user, Tab, password, Enter.

### 4.5. Daily use — auto path (F5 VPN)

F5 login window raises → `windowActivated` fires → daemon matches,
re-verifies foreground, checks cooldown, types `$user$tab$pass$enter`.
No keypress needed.

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

**Nim packages**: `winim` (Windows builds only), `nyml` (YAML),
`unittest2` (test runner), D-Bus binding (hand-rolled via `libdbus`
FFI or `nim-dbus` — decide at Slice 2). Stdlib: `json`, `osproc`,
`streams`, `tables`, `strutils`, `re`, `posix`, `winlean`.

**External (user-installed)**:

- `bw` / `bw.exe` — resolved `bw_path` → PATH → daemon dir.
- KDE Plasma 6 with `xdg-desktop-portal-kde` (default typing backend).
- *Optional* `ydotool` + `ydotoold` — fallback typer; needs
	`/dev/uinput` writable (`input` group via one-time udev rule).
- *Optional* terminal emulator — `$TERMINAL`, then konsole /
	gnome-terminal / alacritty / xterm / wt.exe / cmd.exe.

**Test-only**: Python 3, PyQt6 (Linux smoke target), tkinter
(Windows, bundled), stdlib `http.server` for HTTP-Basic tests.

---

## 7. Cross-compilation

Linux host, `mingw-w64`.

```
# Linux native
nim c -d:release --opt:speed -o:build/vw-autofill src/vwautofill.nim

# Windows cross (after windres step)
x86_64-w64-mingw32-windres packaging/windows/version.rc \
	-O coff -o packaging/windows/version.res

nim c -d:release --opt:speed --os:windows --cpu:amd64 \
	--cc:gcc --gcc.exe:x86_64-w64-mingw32-gcc \
	--gcc.linkerexe:x86_64-w64-mingw32-gcc \
	--passL:packaging/windows/version.res \
	-o:build/vw-autofill.exe src/vwautofill.nim
```

`version.rc` embeds icon, version info, manifest. `nim-mingw.cfg`
pins the cross gcc.

---

## 8. Rule schema

**Everything lives in URIs on `.login.uris`.** Each URI is a
self-contained rule — matchers *and* behavior in the query string.
No `autofill.*` custom fields. Multiple URIs on one item = one
credential across many windows, each URI with its own behavior
(different modes / sequences / cooldowns are fine and often the
point). Extends bitwarden-autotype's URI convention; the matching
subset stays compatible (extensions ignored gracefully).

### 8.1. URI grammar

Schemes:

| Scheme | Matches on |
|---|---|
| `winapp://...` | Windows only |
| `linapp://...` | Linux only |
| `app://...` | Either OS (matches against the local OS's exe) |

URI body:

```
<scheme>://<exe>?<key>=<value>&<key>=<value>...
```

`<exe>` is one of: empty (query attrs alone — e.g.
`winapp://?class=MozillaDialogClass&text=cotauth.toronto.ca`),
a basename (`f5fpclientW.exe`, `firefox`), or a full path via the
URI triple-slash convention (`winapp:///C%3A/Program%20Files/F5%20VPN/f5fpclientW.exe`).

Query attrs split into **matchers** (gate firing) and **behavior**
(what to do when fired). The sequence template (§9) is designed to be
URI-safe without percent-encoding.

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

### 8.2. Examples

"School VPN" item, two URIs (one credential, two windows, both auto):

```
winapp:///C%3A/Program%20Files%20(x86)/F5%20VPN/f5fpclientW.exe?title_regex=%5EF5%20BIG-IP.*Logon%24&mode=auto
winapp://?class=MozillaDialogClass&text=vpn.school.edu&mode=auto
```

"School Auth" item (hotkey, defaults):

```
linapp://firefox?class=MozillaDialogClass&text=cotauth.toronto.ca
```

Mixed modes per URI (Thunderbird auto, browser hotkey, same credential):

```
linapp://thunderbird?class=Thunderbird&text=imap.school.edu&mode=auto
linapp://firefox?class=MozillaDialogClass&text=mail.school.edu
```

### 8.3. Match semantics

Per URI: scheme matches OS, exe matches foreground (full path if the
URI used one, else basename), every matcher attr matches foreground
state. Candidate-resolution across all items:

- **0**: no fill (or picker if `fallback_picker: true`).
- **1**: fire with that URI's behavior.
- **2+ on same item**: fire once with the most-specific URI (most
	matchers; tie → first listed).
- **2+ across items**: ambiguous — log contenders, do nothing.

Exe comparison: case-insensitive on Windows, case-sensitive on Linux.
Full-path comparison is literal post URI-decode; symlinks not resolved
(capture stores what `/proc/<pid>/exe` or `QueryFullProcessImageNameW`
returned).

### 8.4. Validation

Per URI at load time:

- URI parses (scheme, query syntax, regex compiles, sequence template
	parses, `mode` / `field_check` values known, `cooldown` non-negative).
- `mode=auto` requires exe + ≥1 other matcher.
- Exe-only URIs require `unsafe=1`.
- A failed URI is skipped with a warning; others on the same item
	still load.

### 8.5. Cross-tool compatibility

Matching subset (schemes, `?title=`, `?class=`, full path / basename)
works with stock bitwarden-autotype unchanged. Behavior params
(`mode`, `sequence`, `cooldown`, `field_check`, `unsafe`) and matcher
extensions (`title_regex`, `text`) are ignored by it without breaking.

---

## 9. Sequence template language

URI-safe by design — `$`, `:`, letters, digits are all in RFC 3986
unreserved / sub-delim, so the template ships unencoded inside
`sequence=`.

Tokens:

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

Case-insensitive token names. Text between tokens is typed literally.
Escape literal `$` as `$$`. Parser: scan literal up to next `$`; at
`$`, `$$` → literal, else read `[A-Za-z]+` as token name; if next
char is `:`, read `[^$]*` (greedy) as parameter (use `$$` for literal
`$` inside the value).

```
$user$tab$pass$enter                  → classic
$user$tab$pass$delay:500$enter        → 500ms pause before Enter
$user@example.com$tab$pass$enter      → literal email suffix
$$5 charge$tab$pass$enter             → types '$5 charge' then tab + pass + enter
$field:apiKey$enter                   → custom field lookup
```

Tokenize once at load time into `SeqOp = enum opText, opType, opKey,
opDelay`; renderer walks ops.

---

## 10. Capture flow

See §4.3 for UX. Architectural rules:

- Client owns prompts (plain stdio, zero deps); daemon owns snapshot.
- Writeback (§13.2): `bw get item` → modify `.login.uris` (append /
	replace / remove URI) → `bw encode` → `bw edit item`. The client
	requests this via the daemon so only the daemon holds the session
	token.
- For UIA/AT-SPI capture: walk the focused element up one level,
	concatenate readable strings, suggest the longest URL-bearing
	substring as the `text=` matcher.

### 10.1. Snapshot contents

`exe_path`, `exe_basename`, window title, window class (or Wayland
`resourceClass`), focused-element role + IsPassword, plus the short
ancestor-walk string for the `text=` suggestion.

### 10.2. Snapshot timing (no second hotkey press)

The capture-hotkey press itself is the snapshot moment — the daemon
snapshots immediately, *then* spawns the terminal. Per platform:

- **Linux**: KDE custom shortcut runs `vw-autofill add-interactive`;
	it sync-IPCs the daemon for a snapshot (stashed under a 30s TTL
	pending-ID), then spawns the terminal with `--use-pending=<id>`.
- **Windows**: daemon owns the capture hotkey via `RegisterHotKey`,
	snapshots in the WM_HOTKEY handler, then spawns the terminal with
	`--use-pending=<id>`.

Either way the snapshot is captured before the terminal window steals
focus.

---

## 11. Trigger flows

**Hotkey**: fill hotkey → `daemon.onFillRequest()` → resolve
foreground (`exe`, `title`, `class`) + focused element (`role`,
`isPassword`) → match against URIs with `mode ∈ {hotkey, auto}` →
1 match: cooldown / render / type / record; 0: log (+ optional
picker); 2+: log "ambiguous match: <names>", do nothing.

**Auto**: window-activation event → `daemon.onWindowActivated({pid,
caption, resourceClass})` → resolve exe from pid → match against URIs
with `mode=auto` → cooldown + re-verify foreground + type, else ignore.

Cooldown keyed by `(uri, hwnd-or-windowId)`, lasts the URI's
`cooldown=` seconds (default 15, configurable via
`default_cooldown_s`).

---

## 12. Platform plumbing

### Linux (KDE Plasma 6 Wayland)

**Status:** core path [DONE] — KWin script → D-Bus → daemon → ydotool
typing. AT-SPI [TODO]. Portal RemoteDesktop [DEFERRED] (denies on user's
session; kept as future no-admin distribution path).

**KWin script** (`data/kwin-script/contents/code/main.js`):

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

Installed via `kpackagetool6 -t KWin/Script -i kwin-script/` or
dropped in `~/.local/share/kwin/scripts/`; enabled via System Settings
→ KWin Scripts.

**Daemon side**: [DONE] registers D-Bus name `org.vwautofill.Daemon`
(actual name; differs from plan above). Methods landed:
`WindowActivated`, `Fill`, `LastWindow`, `Reload`. Uses `nim-dbus`
package (libdbus FFI) rather than hand-rolled bindings. [DEFERRED]
`/proc/<pid>/exe` — KWin's `resourceName` is sufficient for matching
in practice; full-path resolution can be added if needed. [TODO]
AT-SPI focused-element / Role read.

#### 12.1. Typing backends on Linux

**Status:** ydotool is the primary backend, not the fallback. Portal
deferred. `LinuxTyper` abstraction not yet a real interface — the
typing module shells out to ydotool directly.

**Portal** — [DEFERRED] `org.freedesktop.portal.Desktop` RemoteDesktop
denied on user's session ("Location services disabled (36)" at the
policy hub level for both RemoteDesktop and Screencast). Kept on the
roadmap as a no-admin distribution option for other users.

**ydotool** — [DONE] `osproc.startProcess('ydotool', ['type', '--',
text])`, key codes for Tab/Enter. Hardcoded device id
`2333:6666` lives in `src/vw_autofill/linux_consts.nim`. Needs
`ydotoold` running. udev/group setup is the user's responsibility
today; systemd user unit is on the to-do list.

**Hotkey**: [DONE] **revised approach** — the KWin script itself
registers the shortcut via `registerShortcut` (default `Meta+Alt+V`),
visible/rebindable under System Settings → Shortcuts → KWin. No KDE
Custom Shortcut / khotkeys involvement needed. There's also a wrapper
script `scripts/vw-fill-shortcut.sh` if the user prefers to bind via
Custom Shortcuts (kept for diagnosis; logs invocations).

### Windows

**Daemon**: hidden message-only window dispatches hotkey + WinEvents.
`SetWinEventHook(EVENT_SYSTEM_FOREGROUND, EVENT_SYSTEM_FOREGROUND,
NULL, callback, 0, 0, WINEVENT_OUTOFCONTEXT)` — out-of-context to
avoid in-process injection. Callback enqueues to a Nim channel.

**Active window**: `GetWindowThreadProcessId` → `OpenProcess(PROCESS_QUERY_LIMITED_INFORMATION)`
→ `QueryFullProcessImageNameW`; `GetWindowTextW` + `GetClassNameW`.

**UIA field detection**:

```nim
let auto = CoCreateInstance(CLSID_CUIAutomation, ...).as(IUIAutomation)
var elem: IUIAutomationElement
auto.GetFocusedElement(&elem)
let controlType = elem.CurrentControlType  # e.g. UIA_EditControlTypeId
let isPassword = elem.GetCurrentPropertyValue(UIA_IsPasswordPropertyId)
```

Walk to parent, concat `CurrentName`/`CurrentHelpText` for the `text=`
matcher.

**Typing**: `SendInput` — Unicode text via `KEYEVENTF_UNICODE` (one
INPUT per UTF-16 code unit, paired down/up); special keys via VK
codes with `KEYEVENTF_KEYUP`. Batch per token.

**Hotkey**: `RegisterHotKey(NULL, HOTKEY_ID_FILL, MOD_CONTROL|MOD_ALT,
'B')` + `RegisterHotKey(NULL, HOTKEY_ID_CAPTURE, MOD_CONTROL|MOD_SHIFT,
VK_OEM_1)`. Message loop dispatches `WM_HOTKEY`.

#### 12.2. UIPI / integrity-level injection failures

UIPI blocks `SendInput` into processes at higher integrity. A
medium-integrity (no-admin) daemon can't type into a high-integrity
target — needs to be surfaced, not failed silently.

Probe both sides via `GetTokenInformation(TokenIntegrityLevel)`:
`daemon_integrity` on startup; `target_integrity` per-target via
`OpenProcessToken(target_pid, TOKEN_QUERY)` (access-denied →
`unknown`). Derive `can_inject` ∈ {yes, no, unknown}.

Behavior:

- `can_inject=no`: skip, log "target is elevated, daemon cannot inject
	(UIPI); see vw-autofill doctor", surface in `status` as last-skip.
- `can_inject=unknown`: try once; if `SendInput` returns 0, mark the
	hwnd as high-integrity for the rest of the daemon's lifetime.
- F5 typically runs at medium so this shouldn't bite for the main
	target, but other apps might.

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

No `unlock(password)` method — by design (§13.1). The only secret
the daemon ever holds is the **bw-issued session token**. `BwBackend`
shells out to `bw` (resolved `bw_path` → PATH → daemon dir); token is
held in memory and persisted to a local file (mode 0600, `O_NOFOLLOW`)
or read from env via `VW_AUTOFILL_SESSION_FROM_ENV=1`.
`FakeVault` in `tests/harness/` implements all methods in-memory.

### 13.1. Unlock UX — daemon never touches the master password

Hard rule: vw-autofill never reads, prompts for, stores, or forwards
the master password. Only `bw` sees it.

Three entry points, all converging on the same pipeline:

1. **Manual**: `bw unlock --raw | vw-autofill unlock` in any terminal.
	`bw` prompts in *its* TTY, prints the session token on stdout;
	the client reads stdin and calls `setSessionToken` over IPC.
2. **Interactive helper**: `vw-autofill unlock-interactive` spawns the
	user's terminal (Linux: `$TERMINAL` → konsole / gnome-terminal /
	alacritty / xterm; Windows: `wt.exe` → `cmd.exe`) running pipeline 1.
3. **Notification-driven**: on locked state, daemon posts a desktop
	notification ("vault locked — click to unlock") whose default
	action runs `unlock-interactive`. Linux uses
	`org.freedesktop.Notifications`; Windows uses a toast.

**Startup**: read `session_token_path` (if present, `setSessionToken`
+ probe `status()`); on `vsLocked` / `vsUnauthenticated`, post the
notification and wait (debounced if fills/captures arrive locked).

**Security properties**: vw-autofill argv/env/stdin/code never accept
a password; session token file is `O_NOFOLLOW` + 0600; expired
sessions degrade cleanly to the notification path.

**Trade-off**: one extra step per session expiry (~daily with `bw`
defaults). Users who want zero-touch can extend the `bw` timeout or
use bw's keyring integration.

### 13.2. `updateItem` pipeline (`bw encode` required)

`bw edit item` reads **base64** from stdin (via `bw encode`), not raw
JSON. Skipping `bw encode` silently fails or produces malformed
items. `BwBackend.updateItem`:

```
1. bw get item <id> --session <token>          → JSON
2. modify in memory: append/replace/remove URI on .login.uris
   (.fields untouched)
3. echo <new-json> | bw encode | bw edit item <id> --session <token>
```

Steps 3+4 run as one `osproc` pipeline so the JSON never hits disk.

Slice 2 integration test: real Vaultwarden + real `bw`, create-modify-
fetch-assert, catches `bw encode` regressions and JSON-shape drift.

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

Loader: `nyml`. Missing keys → compiled-in defaults; unknown keys →
warning (not error) so old configs survive schema evolution.

All config is **local in v1**. Only rules sync through Vaultwarden
(URIs on login items). Vault-side config overlay is in §22.

---

## 15. Safety controls

Baked into the rule loader and trigger logic:

1. Reject exe-only URIs without `unsafe=1`. Titles are app-settable
	(phishing vector); exe paths are not.
2. Re-verify foreground in the ~50 ms before typing; abort if changed.
3. Per-URI cooldown (default 15 s) keyed by `(uri, window)`.
4. `auto` mode is opt-in per URI; default is `hotkey`.
5. `field_check=password` refuses to type until focused element
	reports as password. (UIA on Trident is mediocre, so leave unset
	for F5 and rely on exe + title.)
6. Daemon never logs typed values — only rule name + timing.
7. No autostart by default; explicit `enable-autostart` only.

---

## 15a. `vw-autofill doctor`

End-to-end environment checks, one pass/warn/fail line per check.
Exit 0 if all pass.

**Common**: `bw` resolves; `bw --version` ≥ minimum; `bw status`
authenticated; session token valid; daemon IPC ping; rules loaded
(with skipped count).

**Linux**: KDE Plasma ≥ 6.3 (`$XDG_CURRENT_DESKTOP=KDE`); KWin script
installed under `~/.local/share/kwin/scripts/vw-autofill/` and
enabled (`kreadconfig6 --group Plugins --key vw-autofillEnabled`);
`org.freedesktop.portal.RemoteDesktop` present; restore token
validates or first-run prompt available; `org.a11y.Bus` present;
ydotool (if selected): `--version` works and `/dev/uinput` writable.

**Windows**: named pipe connectable; `RegisterHotKey` succeeded for
both hotkeys; `daemon_integrity` (expected medium under no-admin);
`CoCreateInstance(CLSID_CUIAutomation)` succeeds; optional Notepad
inject smoke.

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

- Build: `-d:release --opt:speed` (not `-d:danger`, not `--opt:size`);
	keep symbols.
- Size target: ~500 KB–1.5 MB. Under ~150 KB is itself a heuristic
	red flag — pad with a small static resource (icon + strings) if
	needed.
- Embed: `manifest.xml` with `asInvoker / uiAccess=false`; full version
	info (CompanyName, FileDescription, ProductName, OriginalFilename,
	LegalCopyright, FileVersion, ProductVersion); icon.
- No UPX, no obfuscation. Don't bundle `bw.exe`.
- Prefer `SetWinEventHook` (out-of-context) over
	`SetWindowsHookEx(WH_KEYBOARD_LL)`.
- No autostart on first run; explicit `enable-autostart` writes
	`HKCU\…\Run`.

If Defender flags it: submit to
<https://www.microsoft.com/en-us/wdsi/filesubmission> (turnaround days);
per-user exclusion is the immediate workaround (may not be available
under school MDM).

---

## 18. Testing

Comprehensive auto-tests are non-negotiable. Manual tests only where
the OS event surface can't be mocked (real keystrokes, real KWin,
real Defender).

### 18.1. Test categories

**Unit** (per-module, fast, no I/O):

- `test_rules`: 30+ URI shapes (full-path / basename / query-only /
	malformed); invalid regex rejected; exe-only requires `unsafe=1`;
	`mode=auto` requires another matcher; defaults applied; platform
	filter; parse ↔ serialize round-trip preserves attrs.
- `test_seq_template`: tokenize / render, `$$` escape, unknown tokens,
	`$delay:N` / `$field:Name` params, empty seq, trailing `$`,
	unicode, parameter terminated by next `$`.
- `test_vault_parse`: 20+ `bw get items` snapshot shapes — missing
	fields, deleted items, no-login items, malformed URIs.
- `test_match`: every match dimension (exe-only, exe+title_regex,
	exe+class, exe+class+text); positives and negatives; OS filter;
	case-insensitive exe on Windows.
- `test_capture`: scripted stdin + fake snapshot → assert `bw edit`
	payload contains expected URI on `.login.uris`.

**Integration** (run anywhere, via three fakes):

- `FakeVault` (in-memory backend; tests assert on writes).
- `FakePlatform` (synthesizes events, supplies focused element,
	records emitted keystrokes).
- `FakeBus` (synchronous in-process).

End-to-end cases: hotkey fill (unique / no-match / ambiguous); auto
fire; auto-fire cooldown; foreground race (abort); `field_check=password`
gate; capture round-trip (exact URI written); vault-locked-at-startup
(prompt → unlock); `bw` exits 1 (clean error, no crash).

**Property tests** (deterministic seed):

- Sequence: `tokenize ∘ render` ≈ id modulo escape-unification.
	Generators include `$$` escapes and `$NAME:value` params.
- URI: arbitrary `Rule` → URI → `Rule` is identity; generators cover
	all attrs.

**Platform smoke** (gated, opt-in; smoke-target apps may be Python):

- Linux: PyQt6 app `tests/smoke/target_linux.py` (`QLineEdit` +
	`QLineEdit(echoMode=Password)`, JSON log on every change; Qt
	exposes AT-SPI). Harness launches app, sends D-Bus `fill`, asserts
	log contents. Needs display server.
- Windows: tkinter equivalent (`target_windows.py`) — tkinter uses
	Win32 `Edit` controls, so UIA sees them. Manual or GUI Windows CI.
- HTTP-Basic: `basic_auth_server.py` (stdlib `http.server`, returns
	401 Basic, logs creds); user points Firefox at it, daemon fills,
	harness asserts.

**Build** (`tools/check.sh`): `nim check`; `nimble test`; Linux build;
Windows cross-build (compile only); PE size check (warn outside
300 KB–2 MB); `--version` smoke (Linux). Non-zero on any failure.

**Real-`bw` integration** (Slice 2): disposable Vaultwarden (Docker)
or test account; create item → `updateItem` with new URI →
re-fetch → assert URI preserved byte-for-byte. Catches `bw encode`
regressions that fixtures can't.

**No Wine**: Wine doesn't reproduce UIA / `SendInput` reliably. All
Windows platform tests run on real Windows — user's laptop or a real
runner. Linux only does the compile-only cross-build check.

### 18.2. Mocking strategy

Daemon main loop is one function taking `(VaultBackend, Platform, Bus)`
— tests instantiate with the fake trio; real entry point in
`vwautofill.nim` just wires up real impls. Every path except platform
glue runs on the build host.

### 18.3. Coverage

≥ 90% line coverage on `rules.nim`, `seq_template.nim`, `match.nim`,
`capture.nim`, `vault.nim` (parse/serialize half). Every CLI
subcommand: happy path + one documented failure path. Measured via
`nim --debugger:native -d:coverage` + lcov (Linux). CI gate 85%
overall.

### 18.4. CI

Local-only initially (`tools/check.sh`). If remoted: Linux job (full
unit + integration + coverage + native + Windows cross-compile);
optional real-Windows job for platform smoke. No Wine.

### 18.5. Test discipline

- Feature commits add tests; bug fixes add regression tests that fail
	before the fix.
- No skipped/disabled tests; if a test can't run on a platform, gate
	at the test level with a reason.
- Fixtures are real scrubbed `bw get items` outputs, not hand-rolled
	dicts — keeps them honest against `bw` shape drift.

---

## 19. Implementation order

Front-load platform proof — riskiest parts (KDE Wayland portal,
AT-SPI, Windows UIA / SendInput, UIPI) get proven in throwaway demos
before code depends on them. Each slice ships its own tests; no slice
"done" until `tools/check.sh` is green.

### Slice 0 — Platform proof (Linux first, throwaway demos)

**Status:** done in spirit, not file-structure. We did `scripts/recon.sh`
and `scripts/recon2.sh` instead of `tools/proof/<name>/` separate
programs — those probes told us portal was denied (hub policy), KWin 6
dropped `clientActivated` (only `workspace.windowActivated` survives),
and ydotool was the viable typing path.

1. **`portal-type/`** — [DEFERRED] portal RemoteDesktop denied on
	user's session. Future no-admin path.
2. **`atspi-focus/`** — [TODO] not yet proved.
3. **`kwin-event/`** — [DONE] via recon scripts + the production KWin
	watcher script.
4. **`win-sendinput/`** — [TODO] Windows slices not started.

### Slice 1 — Rule schema + sequence template

**Status:** core [DONE], full sequence-template language [PARTIAL],
config/log modules [TODO].

- `src/vw_autofill/rule.nim` + `uri.nim` + `match.nim` — [DONE]. 26
	unit tests pass; URI parse + match logic exercised. No round-trip
	property tests yet.
- Sequence templating — [PARTIAL]. Lives inline in
	`src/vw_autofill/typing.nim` (`playSequence`). Supports `$user`
	`$pass` `$totp` `$tab` `$enter`. Missing: `$delay:N`, `$field:NAME`,
	`$key:NAME`, `$shifttab`, `$$` escape.
- `config.nim` (YAML) — [TODO]. Today everything is env vars + URI
	query params.
- `log.nim` structured logger — [TODO]. Daemon has a `d.log` helper
	but it's not a real logger.

### Slice 2 — `bw` backend with real edit round-trip

**Status:** read [DONE], write [DONE], automated round-trip test
[TODO].

- `src/vw_autofill/vault.nim` — [DONE]. `runBw` separates stdout from
	stderr (which prevented JSON parse breakage from Node deprecation
	warnings). `parseBwJson` wraps with diagnostic context.
- `bwAddUriToItem` — [DONE]. `bw get item <id>` → mutate JSON →
	`bw encode | bw edit item <id>`. Used by `capture`.
- `vw-autofill list` — [DONE]. Verified against the user's real
	Vaultwarden.
- `test_vault_parse.nim` + Docker-Vaultwarden round-trip — [TODO].

### Slice 3 — Linux daemon (D-Bus + KWin + portal + AT-SPI)

**Status:** primary path [DONE]; portal/AT-SPI [DEFERRED/TODO].

- `src/vw_autofill/daemon.nim` — [DONE]. Single module covers what the
	plan split into platform_linux + bus_linux. Uses `nim-dbus` (libdbus
	FFI). Methods: `WindowActivated`, `Fill`, `LastWindow`, `Reload`,
	plus Introspectable + Peer compat. Hardened `requestName` with
	REPLACE_EXISTING so stale processes can't squat the name.
- `data/kwin-script/contents/code/main.js` — [DONE]. Forwards
	activations + registers the Fill shortcut via `registerShortcut`.
- `src/vw_autofill/typing.nim` ydotool wrapper — [DONE].
- `/proc/<pid>/exe` resolution — [DEFERRED]. KWin's `resourceName`
	suffices for current matching.
- Portal RemoteDesktop typer — [DEFERRED]. Hub-policy deny on user.
- AT-SPI focused-element + Role — [TODO].
- `fake_platform.nim` / `fake_bus.nim` test harnesses — [TODO]. We've
	been verifying live in a private `dbus-run-session` instead.

### Slice 4 — Linux hotkey + fill flow

**Status:** primary path [DONE]; cooldown / foreground re-verify /
field-check / ambiguity handling [TODO].

- Hotkey → Fill → match → type — [DONE]. Cleaner than the plan:
	hotkey is registered inside the KWin script (`registerShortcut`,
	default `Meta+Alt+V`, rebindable in System Settings). No external
	KDE Custom Shortcut config required.
- Verified end-to-end: real ydotool typing into a focused window via
	the hotkey, against a real Vaultwarden item.
- [TODO] cooldown enforcement, foreground re-verify, `field_check`
	gating, ambiguity logging, integration tests for each case.

### Slice 5 — Capture / add flow

**Status:** capture [DONE]; edit / delete / add-interactive dropped
from v1 scope.

- `vw-autofill capture` — [DONE]. Inline in `src/vw_autofill.nim`
	(no separate `capture.nim`). Flow: ping daemon → verify or prompt
	for session token → 5-sec focus countdown → fetch `lastWindow` from
	daemon via `LastWindow()` → fzf-pick a vault item → prompt for
	sequence / matchers / mode (fzf for the binary choices) → build URI
	→ `bw edit item` via `bwAddUriToItem` → `Reload` the daemon. No
	paste, no `bw sync`, no daemon restart.
- `vw-autofill edit` / `delete` — [DROPPED]. Vault items are editable
	via the Bitwarden web UI; not worth re-implementing URI mutation in
	our CLI when the user already has a good editor.
- `vw-autofill add-interactive` (spawn terminal) — [DROPPED]. `capture`
	itself is interactive enough.
- `test_capture.nim` — [TODO].

### Slice 6 — Linux smoke + user validation

**Status:** ad-hoc user-validation [DONE]; automated smoke targets +
doctor [TODO].

- User-driven validation against a live Vaultwarden, real KWin script,
	real ydotool typing — [DONE]. Confirmed working.
- `tests/smoke/target_linux.py` (PyQt6) + `run_smoke.sh` — [TODO].
- `basic_auth_server.py` — [TODO].
- `vw-autofill doctor` (§15a) — [TODO].

### Slice 7 — Windows platform

**Status:** [TODO]. Not started; Linux first per the user's direction.

`platform_windows.nim`, `platform_windows_uia.nim`, `bus_windows.nim`,
`test_bus_windows.nim`, `test_platform_windows.nim`. WinEventHook
listener; hwnd→exe; UIA focused-element + IsPassword; `SendInput`
typer with UIPI probe; `RegisterHotKey`; named-pipe IPC. Same test
suite as Slices 3–5, on real Windows (no Wine). Done when: UIPI probe
correctly reports `daemon_integrity` / `target_integrity`.

### Slice 8 — Cross-compile + packaging

**Status:** [TODO]. Not started.

`nim-mingw.cfg`, `packaging/windows/*`, `tools/build-windows.sh`,
`tools/check.sh`. `make windows` produces `vw-autofill.exe` with
embedded manifest / version info / icon. Defender scan after transfer;
iterate if flagged. Done when: built exe runs without admin and
Defender leaves it alone.

### Slice 9 — Windows smoke + user validation

**Status:** [TODO]. Not started.

`tests/smoke/target_windows.py` (tkinter) + parallel runner; regression
fixtures for Windows-specific quirks. Done when: F5 fills with one
hotkey press; `doctor` passes on the user's Windows laptop.

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

Bitwarden secure note `vw-autofill.config` whose YAML body overlays
the local config for *behavior* keys (default sequence / cooldown /
hotkeys / fallback_picker). Bootstrap keys (`bw_path`,
`session_token_path`, `portal_restore_token_path`, `log_level`) stay
local to avoid chicken-and-egg with `bw` resolve + unlock. Cut from
v1 because it adds config merging / sync / reload semantics before the
core works; clean to add later on top of `bw sync`.

### TOTP autofill

`$totp` token in the sequence template, wired through `bw get totp
<id>`. Token reserved in §9; mostly plumbing.

### Other targets

- **macOS** — `CGEventPost` + NSAccessibility + bw on PATH. Same
	architecture.
- **X11 / XWayland on Linux** — `XTestFakeKeyEvent` + `XQueryTree`.
	Drops into the existing platform abstraction.
- **Other Wayland compositors** (sway, Hyprland) —
	`wlr-foreign-toplevel-management` in place of the KWin script.

Cut reasons: not needed for F5 + cotauth (TOTP, GUI); too much
complexity before core works (secure-note overlay); platform scope
creep (macOS, X11, other compositors). Bring back one at a time
after v1.
