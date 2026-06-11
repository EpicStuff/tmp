# vaultwarden-autofill — Alternatives surveyed

Captured before starting implementation, so future-us (and anyone
else asking "didn't this already exist?") can see the landscape and
the reasoning. Snapshot date: 2026-06.

For each tool: what it does, what's missing for our requirements,
whether it influenced the design.

## Our hard requirements (for reference)

- Windows + Linux (KDE Plasma 6 Wayland).
- Backed by Bitwarden / self-hosted Vaultwarden.
- Auto window matching — focused window → unique vault entry,
	no picker.
- Hotkey is fine; auto-fire on window activation is nice-to-have
	(F5 only).
- Field-type detection (text vs password) where possible.
- No Windows admin permission available.
- AV-conscious on Windows.
- Single Nim codebase for both platforms.

## Bitwarden ecosystem — Windows

### bitwarden-autotype (AutoHotkey) — anonymous1184 + forks

- <https://github.com/anonymous1184/bitwarden-autotype> (v1.1.4,
	Feb 2022) and forks
	[cxntered](https://github.com/cxntered/bitwarden-autotype),
	[pa-0/bw-autotype](https://github.com/pa-0/bw-autotype),
	[brendanmeyer](https://github.com/brendanmeyer/bitwarden-autotype),
	[hulmgulm](https://github.com/hulmgulm/bitwarden-autotype),
	[FrozenGhostx](https://github.com/FrozenGhostx/bitwarden-autotype).
- Windows only, AHK v1, hotkey-triggered (`Ctrl+Alt+A`).
- Matches by URI / exe / window title / window class via the
	`winapp://` URI convention on Bitwarden items. **This is the
	convention vaultwarden-autofill adopts** (with extensions —
	see §8 of PLAN.md).
- No auto-fire on activation, no UIA field-type gating.
- Why not just use it: school IT blocks AHK installation /
	execution on the user's Windows laptop.

### MCOfficer/bitwarden-autotype

- <https://github.com/MCOfficer/bitwarden-autotype> — WIP,
	Windows-only.

## Bitwarden ecosystem — Linux

### rofi-rbw — fdw

- <https://github.com/fdw/rofi-rbw>
- Most actively maintained Linux Bitwarden picker.
- Uses [`rbw`](https://github.com/doy/rbw) (faster Rust Bitwarden
	CLI; works with self-hosted Vaultwarden).
- Frontend-agnostic: rofi / wofi / fuzzel / bemenu — covers X11
	and Wayland.
- Typing: xdotool / wtype / ydotool / dotool — covers X11 and
	Wayland.
- Configurable per-credential autotype sequence via `_autotype`
	field.
- **What it lacks**: no automatic credential-from-window matching.
	User always picks from a list. That's our must-have, so this
	doesn't qualify by itself.

### bitwarden-rofi / bwmenu — mattydebie

- <https://github.com/mattydebie/bitwarden-rofi>
- Bash + rofi + xdotool/ydotool. Linux only.
- Uses the official `bw` CLI rather than rbw.
- Same shortcoming: no window-to-credential auto-matching.

### bitwarden-menu — firecat53

- <https://github.com/firecat53/bitwarden-menu>
- Python + `pynput` + dmenu/rofi/wofi/bemenu.
- Closest to "cross-platform Python" in concept, but the frontend
	is dmenu/rofi-only and the project assumes Linux-style clipboard
	(xsel / wl-copy). Heavier than what we need (it also edits
	vault items from the menu).

## Cross-platform open-source password managers with native auto-type

### KeePassXC

- <https://keepassxc.org/>
- Windows + macOS + Linux. Native Auto-Type with window-title
	matching and per-entry custom sequences (`{USERNAME}{TAB}{PASSWORD}{ENTER}`).
- **Windows**: full window matching, works well.
- **Linux X11 / XWayland**: full window matching, works well.
- **Linux Wayland (today)**: no native auto-type. Workaround is
	`QT_QPA_PLATFORM=xcb` (run under XWayland) — window matching
	then only works against other X11/XWayland apps.
- **Linux Wayland (imminent)**: PR
	[#13359](https://github.com/keepassxreboot/keepassxc/pull/13359)
	— "Wayland Auto-Type with XDG Desktop Portals" — open,
	mergeable, not draft. Uses Global Shortcuts portal + Remote
	Desktop portal. Works on KDE Plasma 6.6. But: **no window-title
	matching** even with the PR (protocol doesn't expose titles to
	arbitrary clients). UX is "press hotkey → manual picker pops."
- **Field-type detection outside browsers**: not implemented.
- **Cross-tool compatibility with our design**: the
	`xdg-desktop-portal` RemoteDesktop approach is exactly what
	vaultwarden-autofill uses on Linux — directly informed by this
	PR.
- **Why not switch to KeePassXC entirely**: user wants to stay on
	self-hosted Vaultwarden.

### Bitwarden official (desktop app)

- Auto-type/autofill for desktop apps has been on the roadmap
	[since 2018](https://community.bitwarden.com/t/auto-type-autofill-for-logging-into-other-desktop-apps/158)
	and isn't shipped. Cisco's external-browser SAML mode for
	AnyConnect (which OpenConnect now mirrors) was their fallback
	answer.

### pass / passmenu

- pass + passmenu (dmenu) — Linux only, no native auto-type
	mechanism beyond clipboard.

## VPN-specific escape hatches (not autofill tools, but worth knowing)

### OpenConnect `--external-browser` (v9+)

- Cisco AnyConnect-style SAML SSO flow: VPN client launches the
	system browser at the IdP URL, Bitwarden browser extension
	handles the form, token POSTs back to a loopback callback.
- Linux: works in modern OpenConnect (v9, 2022+).
- Sidesteps the embedded webview entirely.
- Only applicable when the VPN auth flow is SAML/SSO with
	external-browser support.

### F5 BIG-IP Edge Client `UseExternalBrowserForAuth` (7.2.5+)

- Same idea: registry switch in
	`HKLM\SOFTWARE\WOW6432Node\F5 Networks\RemoteAccess` flips the
	embedded Trident webview to the default system browser.
- HKLM = needs admin. Ruled out for the user's school laptop.

## Summary

No tool meets all of our requirements as-is. The closest fits:

| Need | Closest existing tool | Gap |
|---|---|---|
| Windows hotkey + auto window match | bitwarden-autotype (AHK) | Blocked by school IT; no auto-fire; no UIA field check |
| Linux KDE Wayland hotkey-fill | rofi-rbw + wtype | No window-to-credential auto-matching |
| Cross-platform auto-type | KeePassXC | Wrong vault backend; Wayland support not shipped; no field detection |
| HTTP Basic auth dialog | none | Bitwarden issue [#116](https://github.com/bitwarden/clients/issues/116) — open |
| F5 BIG-IP Edge Client | none directly | bitwarden-autotype if AHK worked + admin if 7.2.5 |

## Influences carried into the design

- **`winapp://` URI convention from bitwarden-autotype** — adopted
	verbatim, with extensions for regex titles and substring text
	matching, and a `linapp://` sibling. Cross-tool compat: a user
	can also point bitwarden-autotype at the same Bitwarden vault on
	a different Windows machine and the URIs still work for it.
- **`xdg-desktop-portal` RemoteDesktop on Linux** — same path
	KeePassXC PR #13359 takes; the right modern Wayland answer.
- **Custom-field key-value extras** — pattern inspired by rofi-rbw's
	`_autotype` field; we use `autofill.mode`, `autofill.sequence`,
	etc.
- **Hotkey-only is a deliberate baseline** — every survey hit
	confirms auto-on-activation is a security/UX hot potato that no
	mainstream tool ships. Keep `auto` opt-in per item with strict
	matcher requirements.
