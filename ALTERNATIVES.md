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

- <https://github.com/anonymous1184/bitwarden-autotype> — **upstream
	effectively abandoned**. Last release v1.1.4 (Feb 2022), last
	commit on `master` May 2022. The issue tracker (snapshot 2026-06)
	is a steady drip of unresolved 2024–2025 breakage:
	- #64 — every sync fails with `Failed to parse JSON … Unexpected
		character at position 1: 'm'` in `bw-at.exe` (14 comments,
		Aug 2024, no fix).
	- #70 — Firefox URL detection drops after sleep/wake; only fix
		is restart + master password + manual sync (Mar 2025).
	- #65 — stuck in "You are already logged in" state (Sep 2024).
	- #63 — vault won't open if KDF is Argon2id (Jun 2024).
	- #66 — installer has no self-hosted / Vaultwarden option
		(Sep 2024).
	- #71 — "Someone please fork this thing" (Jul 2025). Reporter
		also describes occasional wrong-credential autofill across
		every tab. Title summarises the user vibe.
- Forks with a pulse — both small audiences, each landed one or
	two patches and stopped:
	[cxntered](https://github.com/cxntered/bitwarden-autotype)
	(push 2025-04; fixed "already logged in", added number
	selection),
	[FrozenGhostx](https://github.com/FrozenGhostx/bitwarden-autotype)
	(push 2025-01, 7 stars).
	Stale forks:
	[pa-0/bw-autotype](https://github.com/pa-0/bw-autotype) (2024-02,
	mirror of upstream),
	[brendanmeyer](https://github.com/brendanmeyer/bitwarden-autotype)
	(2022-07),
	[hulmgulm](https://github.com/hulmgulm/bitwarden-autotype)
	(2021-07).
- Windows only, AHK v1, hotkey-triggered (`Ctrl+Alt+A`).
- Matches by URI / exe / window title / window class via the
	`winapp://` URI convention on Bitwarden items. **This is the
	convention vaultwarden-autofill adopts** (with extensions —
	see §8 of PLAN.md). The convention itself is sound — only the
	implementation around it has decayed.
- No auto-fire on activation, no UIA field-type gating.
- Why not just use it as the long-term answer: upstream is dead
	and the live forks are one-person sidecars — we'd be inheriting
	a broken sync layer and a brittle URL-from-Firefox scraper with
	no maintainer upstream of us. It's still the best off-the-shelf
	stopgap on Windows today, and the live forks (cxntered,
	FrozenGhostx) are worth trying before this project ships.

### MCOfficer/bitwarden-autotype

- <https://github.com/MCOfficer/bitwarden-autotype> — WIP,
	Windows-only. Last push 2023-03; appears abandoned.

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
| Windows hotkey + auto window match | bitwarden-autotype (AHK) | Upstream abandoned + unresolved sync/URL bugs; no auto-fire; no UIA field check |
| Linux KDE Wayland hotkey-fill | rofi-rbw + wtype | No window-to-credential auto-matching |
| Cross-platform auto-type | KeePassXC | Wrong vault backend; Wayland support not shipped; no field detection |
| HTTP Basic auth dialog | none | Bitwarden issue [#116](https://github.com/bitwarden/clients/issues/116) — open |
| F5 BIG-IP Edge Client | bitwarden-autotype (URI on `f5fpclientW.exe`) | Hotkey-only (no auto-fire on window activation); subject to upstream bugs; admin-blocked alternative via `UseExternalBrowserForAuth` 7.2.5+ registry |

## Influences carried into the design

- **`winapp://` URI convention from bitwarden-autotype** — adopted
	verbatim, with extensions for regex titles and substring text
	matching, and a `linapp://` sibling. Cross-tool compat: a user
	can also point bitwarden-autotype at the same Bitwarden vault on
	a different Windows machine and the URIs still work for it.
	Given the upstream's current state (see §1), our role isn't just
	"another implementation alongside" — for any user already on
	bw-autotype and hitting the open bugs above, an URI-compatible
	replacement is a usable exit. The convention is a stable contract;
	the impl behind it can be replaced.
- **`xdg-desktop-portal` RemoteDesktop on Linux** — same path
	KeePassXC PR #13359 takes; the right modern Wayland answer.
- **Per-URI behavior in query params** — extends the bitwarden-autotype
	URI convention with `?mode=`, `?sequence=`, `?cooldown=`,
	`?field_check=`, `?unsafe=`. Everything per-rule lives in one URI,
	no auxiliary fields. Sequence-template syntax (`$user$tab$pass$enter`)
	is designed to be URI-safe with no percent-encoding. Whereas
	rofi-rbw uses a separate `_autotype` custom field, our design
	keeps the behavior on the URI that owns the match — one source of
	truth per rule.
- **Hotkey-only is a deliberate baseline** — every survey hit
	confirms auto-on-activation is a security/UX hot potato that no
	mainstream tool ships. Keep `auto` opt-in per URI with strict
	matcher requirements.
