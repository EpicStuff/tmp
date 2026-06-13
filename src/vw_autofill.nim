## vw-autofill — entry point.
##
## Subcommands:
##   list     dump every matchable rule the vault exposes
##   status   report bw vault status
##   daemon   run the session-bus daemon (KWin script + hotkey call into it)
##   fill     tell the running daemon to fire its cached match
##   help     this message
##
## More to come (capture, unlock helper).

import std/[os, json, strutils, uri, osproc, streams, posix, times]
import vw_autofill/[vault, rule, daemon, linux_consts]

proc isForeground(): bool =
  ## True iff stdin's terminal foreground process group is us. False
  ## when we're a backgrounded job (`./bin/vw_autofill daemon &`),
  ## meaning any attempt to read from /dev/tty for a password prompt
  ## would get SIGTTIN'd and hang forever.
  let fg = tcgetpgrp(0.cint)
  if fg == -1: return false  ## no controlling terminal at all
  return fg == getpgrp()

proc persistedSessionPath(): string =
  let dir = getConfigDir() / "vw-autofill"
  if not dirExists(dir):
    createDir(dir)
  dir / "session"

proc readPersistedSession(): string =
  let p = persistedSessionPath()
  if not fileExists(p): return ""
  try:
    result = readFile(p).strip()
  except IOError:
    result = ""

proc writePersistedSession(token: string) =
  let p = persistedSessionPath()
  try:
    writeFile(p, token)
    when defined(posix):
      setFilePermissions(p, {fpUserRead, fpUserWrite})
  except CatchableError as e:
    stderr.writeLine "WARNING: failed to persist session to " & p &
      ": " & e.msg

proc spawnUnlockTerminal(): bool =
  ## Pop open a terminal running `./bin/vw_autofill unlock`. Used by
  ## cmdDaemon when it needs the master password but can't prompt
  ## itself (PLAN.md §13.1). Returns true if a terminal was launched.
  let self = getAppFilename()
  let cmd = @[self, "unlock"]
  var tries: seq[tuple[exe: string, flags: seq[string]]] = @[]
  let term = getEnv("TERMINAL")
  if term.len > 0:
    tries.add((term, @["-e"]))
  for c in [
    ("konsole",        @["-e"]),
    ("kitty",          newSeq[string]()),
    ("alacritty",      @["-e"]),
    ("gnome-terminal", @["--"]),
    ("xterm",          @["-e"]),
  ]:
    tries.add(c)
  for t in tries:
    if findExe(t.exe).len == 0: continue
    try:
      let args = t.flags & cmd
      let p = startProcess(t.exe, args = args, options = {poUsePath})
      p.close()  # fire-and-forget; child keeps running
      stderr.writeLine "spawned " & t.exe & " for unlock"
      return true
    except OSError:
      continue
  return false

proc waitForSessionUpdate(initial: times.Time, timeoutSec = 120): string =
  ## Poll the persisted session file for an mtime > `initial`. Returns
  ## the new token, or empty string on timeout.
  let p = persistedSessionPath()
  let deadline = getTime() + initDuration(seconds = timeoutSec)
  while getTime() < deadline:
    if fileExists(p):
      let mt = getLastModificationTime(p)
      if mt > initial:
        return readPersistedSession()
    sleep(200)
  return ""

proc requireDaemon() =
  try:
    discard sendIntrospect()
  except CatchableError as e:
    stderr.writeLine "Daemon not reachable: " & e.msg
    stderr.writeLine "Start it first: ./bin/vw_autofill daemon"
    quit 1

proc cmdStatus() =
  requireDaemon()
  let raw = sendStatus()
  echo parseJson(raw).pretty

proc cmdList() =
  requireDaemon()
  let lines = sendListRules()
  if lines.len == 0:
    echo "no vw-autofill rules found"
    return
  for l in lines: echo l

proc bwUnlockInteractive(): string =
  ## Spawn `bw unlock --raw` with the prompt routed to /dev/tty so the
  ## user types their master password directly. Capture stdout for the
  ## session token. NOTE: bw still phones home for ServerConfig on
  ## unlock, so this requires the Vaultwarden server to be reachable.
  ## After one successful unlock, the token is persisted (see
  ## persistedSessionPath) so subsequent daemon restarts work offline.
  stderr.writeLine "Unlocking vault (bw unlock --raw)..."
  let p = startProcess(
    "bw unlock --raw 2>/dev/tty </dev/tty",
    options = {poUsePath, poEvalCommand},
  )
  defer: p.close()
  let token = p.outputStream.readAll().strip()
  let code = p.waitForExit()
  if code != 0 or token.len == 0:
    raise newException(IOError, "bw unlock failed (exit " & $code & ")")
  result = token

proc readBwSession(): string =
  ## Priority:
  ##   1. BW_SESSION env (trusted as-is; no `bw status` verify, because
  ##      verify itself calls the Vaultwarden server -- breaks offline)
  ##   2. Persisted token at ~/.config/vw-autofill/session (mode 0600)
  ##   3. Spawn `bw unlock --raw`, then persist the token
  ##
  ## If a stale/bad token makes it past 1-2, later bw operations will
  ## fail with "Vault is locked" -- the daemon catches that on the
  ## D-Bus method handlers; the user can `pkill` and rerun to re-unlock.
  let env = getEnv("BW_SESSION")
  if env.len > 0:
    return env
  let cached = readPersistedSession()
  if cached.len > 0:
    stderr.writeLine "Using cached session from " & persistedSessionPath()
    return cached
  let token = bwUnlockInteractive()
  writePersistedSession(token)
  stderr.writeLine "Session cached at " & persistedSessionPath()
  result = token

proc findKwinScriptSource(): string =
  ## Look for data/kwin-script relative to the binary (the usual repo
  ## layout: <repo>/bin/vw_autofill + <repo>/data/kwin-script), then
  ## next to it (in case the binary was installed alongside).
  let exeDir = getAppFilename().parentDir
  let repoLayout = exeDir.parentDir / "data" / "kwin-script"
  if dirExists(repoLayout): return repoLayout
  let installedLayout = exeDir / "kwin-script"
  if dirExists(installedLayout): return installedLayout
  return ""

proc runCheck(cmd: string): tuple[output: string, code: int] =
  let r = execCmdEx(cmd)
  (r.output, r.exitCode)

proc cmdInstallKwinScript() =
  ## End-to-end KWin script installer:
  ##   - locate data/kwin-script
  ##   - kpackagetool6 remove (ignore failure) + install fresh.
  ##     The upgrade-in-place path can leave Plasma running cached
  ##     bytecode of the old script; remove + install forces a clean
  ##     pickup.
  ##   - kwriteconfig6: tick the script enabled in kwinrc
  ##   - qdbus6 Scripting.stop + Scripting.start to flush + restart
  ##     all scripts (single .start doesn't always re-run our script).
  let src = findKwinScriptSource()
  if src.len == 0:
    stderr.writeLine "Could not find data/kwin-script next to the binary."
    quit 1
  echo "source: ", src

  # Aggressive remove+install instead of -u (upgrade) so Plasma can't
  # reuse a cached compile of the previous script body.
  discard runCheck("kpackagetool6 -t KWin/Script -r vw-autofill-watcher")
  let (iOut, iCode) = runCheck(
    "kpackagetool6 -t KWin/Script -i " & quoteShell(src))
  if iCode != 0:
    stderr.writeLine "kpackagetool6 install failed:"
    stderr.writeLine iOut
    quit 1
  echo "installed."

  # In Plasma 6, Scripting.start alone won't reload code of an
  # already-enabled script. The reliable reload pattern is:
  #   disable in kwinrc -> Scripting.start (Plasma unloads)
  #   enable  in kwinrc -> Scripting.start (Plasma reloads with new code)
  echo "reloading script (disable -> start -> enable -> start)..."
  discard runCheck("kwriteconfig6 --file kwinrc --group Plugins " &
                   "--key vw-autofill-watcherEnabled false")
  discard runCheck("qdbus6 org.kde.KWin /Scripting org.kde.kwin.Scripting.start")
  sleep(500)
  discard runCheck("kwriteconfig6 --file kwinrc --group Plugins " &
                   "--key vw-autofill-watcherEnabled true")
  let (rOut, rCode) = runCheck(
    "qdbus6 org.kde.KWin /Scripting org.kde.kwin.Scripting.start")
  if rCode == 0:
    echo "script reloaded."
  else:
    stderr.writeLine "qdbus6 reload failed: " & rOut

  echo ""
  echo "Default Fill shortcut is Meta+Alt+V. Rebind in:"
  echo "    System Settings -> Shortcuts (search 'vw-autofill')"
  echo ""
  echo "Diagnostic: the script's load/registerShortcut state goes to"
  echo "the daemon log under [kwin-script]. Tail it:"
  echo "    tail -f /tmp/vw-autofill-daemon.log | grep kwin-script"

proc cmdUninstallKwinScript() =
  let (rmOut, rmCode) = runCheck(
    "kpackagetool6 -t KWin/Script -r vw-autofill-watcher")
  if rmCode == 0:
    echo "removed KWin script."
  else:
    stderr.writeLine "kpackagetool6 -r failed: " & rmOut
    quit 1
  discard runCheck(
    "kwriteconfig6 --file kwinrc --group Plugins " &
    "--key vw-autofill-watcherEnabled false")
  discard runCheck(
    "qdbus6 org.kde.KWin /Scripting org.kde.kwin.Scripting.start")
  echo "done."

proc warnIfNoYdotoold(socket: string) =
  if not fileExists(socket):
    stderr.writeLine "WARNING: ydotoold socket " & socket &
      " not present. Fill will fail to type until you start ydotoold:"
    stderr.writeLine "    sudo ydotoold --socket-path=" & socket &
      " --socket-perm=0666"

proc cmdDaemon() =
  ## Resolve a working session by *trying* each candidate (env, cached,
  ## fresh unlock) against the real vault. The previous "trust the
  ## cached token blindly" path crashed startup with VaultError when
  ## the cache was stale (after a relock or password change).
  var session = ""
  var rules: seq[BoundRule]

  proc trySession(s, label: string): bool =
    if s.len == 0: return false
    try:
      let b = newBwBackend(s)
      rules = b.collectRules()
      session = s
      stderr.writeLine "vault: using " & label
      return true
    except CatchableError as e:
      stderr.writeLine "vault: " & label & " is stale (" & e.msg & ")"
      return false

  if not trySession(getEnv("BW_SESSION"), "BW_SESSION env"):
    if not trySession(readPersistedSession(),
                      "cached session from " & persistedSessionPath()):
      if isForeground():
        let token = bwUnlockInteractive()
        writePersistedSession(token)
        if not trySession(token, "fresh unlock"):
          stderr.writeLine "could not load vault even after fresh unlock"
          quit 1
      else:
        # Per PLAN §13.1: when we can't prompt ourselves (backgrounded,
        # autostarted, etc.), spawn the user's terminal running
        # `vw-autofill unlock`. We then wait for the persisted session
        # file to update.
        let p = persistedSessionPath()
        let initialMtime =
          if fileExists(p): getLastModificationTime(p)
          else: fromUnix(0)
        if not spawnUnlockTerminal():
          stderr.writeLine "No terminal emulator found."
          stderr.writeLine "Run `./bin/vw_autofill unlock` in a foreground shell."
          quit 1
        stderr.writeLine "Waiting for unlock (up to 2 minutes)..."
        let token = waitForSessionUpdate(initialMtime)
        if token.len == 0:
          stderr.writeLine "Timed out waiting for unlock."
          quit 1
        if not trySession(token, "spawned-terminal unlock"):
          stderr.writeLine "Spawned unlock produced a token but vault still won't open."
          quit 1

  let socket = getEnv("YDOTOOL_SOCKET", DefaultYdotoolSocket)
  let logPath = getEnv("VW_AUTOFILL_LOG", "/tmp/vw-autofill-daemon.log")
  warnIfNoYdotoold(socket)
  let b = newBwBackend(session)
  let d = newDaemon(rules, socket, logPath)
  let backend = b
  let sessionCopy = session
  d.reloadProc     = proc(): seq[BoundRule] = backend.collectRules()
  d.listLoginsProc = proc(): seq[Credential] = backend.listLogins()
  d.addUriProc     = proc(itemId, uri: string) =
    bwAddUriToItem(itemId, uri, sessionCopy)
  d.statusProc     = proc(): JsonNode = backend.status()
  d.serve()

proc cmdReload() =
  let n = sendReload()
  echo "reloaded: ", n, " rule(s)"

proc cmdFill() =
  sendFill()

proc cmdUnlock() =
  ## Explicit interactive unlock. Useful when you want to background
  ## the daemon afterward (a backgrounded daemon can't prompt for the
  ## master password itself -- see isForeground in cmdDaemon).
  if not isForeground():
    stderr.writeLine "unlock needs a foreground shell (it prompts for the master password)"
    quit 1
  let token = bwUnlockInteractive()
  writePersistedSession(token)
  echo "session persisted to ", persistedSessionPath()

proc cmdIntrospect() =
  ## Talk to the running daemon via the same nim-dbus library it serves
  ## with — bypasses busctl's introspect quirks.
  echo sendIntrospect()

proc cmdSimulate() =
  ## Synthesize a WindowActivated call to the daemon. Useful for testing
  ## the matcher path without KWin.
  ##   vw-autofill simulate <exe> <title> [class] [pid]
  if paramCount() < 3:
    stderr.writeLine "usage: vw-autofill simulate <exe> <title> [class] [pid]"
    quit 1
  let exe   = paramStr(2)
  let title = paramStr(3)
  let cls   = if paramCount() >= 4: paramStr(4) else: ""
  let pid   = if paramCount() >= 5: parseUInt(paramStr(5)).uint32 else: 0'u32
  sendWindowActivated(exe, title, cls, pid)
  echo "sent WindowActivated(exe=", exe, ", title=", title,
       ", class=", cls, ", pid=", pid, ")"

proc promptDefault(prompt, default: string): string =
  stdout.write(prompt)
  if default.len > 0: stdout.write(" [" & default & "]")
  stdout.write(": ")
  stdout.flushFile()
  let line = readLine(stdin).strip()
  if line.len == 0: default else: line

proc fzfPick(prompt: string, choices: openArray[string]): string =
  ## Show `choices` in fzf if available; fall back to a numeric
  ## menu if not. Empty result means the user cancelled (esc / no
  ## selection).
  if findExe("fzf").len > 0:
    let p = startProcess(
      "fzf",
      args = @["--prompt=" & prompt & "> ", "--height=30%", "--reverse",
               "--no-multi"],
      options = {poUsePath, poStdErrToStdOut},
    )
    p.inputStream.write(choices.join("\n"))
    p.inputStream.close()
    result = p.outputStream.readAll().strip()
    discard p.waitForExit()
    p.close()
    return
  echo prompt, ":"
  for i, c in choices: echo "  ", i+1, ") ", c
  stdout.write("pick [1]: "); stdout.flushFile()
  let raw = readLine(stdin).strip()
  let idx =
    if raw.len == 0: 0
    else:
      try: parseInt(raw) - 1 except ValueError: -1
  result = if idx >= 0 and idx < choices.len: choices[idx] else: ""

proc cmdCapture() =
  ## Interactive rule-creation flow. Vault access goes through the
  ## daemon, so the caller does NOT need BW_SESSION — the daemon
  ## already holds an unlocked session.
  ##   1. ping daemon
  ##   2. fetch vault items via daemon
  ##   3. countdown for user to focus the target window
  ##   4. fetch lastWindow from daemon
  ##   5. fzf-pick the vault item
  ##   6. prompt for sequence / matchers / mode
  ##   7. ask daemon to push URI to the chosen item (and reload its cache)
  try:
    discard sendIntrospect()
  except CatchableError as e:
    stderr.writeLine "Daemon not reachable: " & e.msg
    stderr.writeLine "Start it first: ./bin/vw_autofill daemon"
    quit 1

  var items: tuple[ids, names: seq[string]]
  try:
    items = sendListItems()
  except CatchableError as e:
    stderr.writeLine "ListItems failed: " & e.msg
    quit 1
  if items.ids.len == 0:
    echo "no login items in vault"
    quit 1

  let delay = 5
  echo "Focus the target window in the next ", delay, " seconds."
  for i in countdown(delay, 1):
    stdout.write("  ", i, "...")
    stdout.flushFile()
    sleep(1000)
  echo ""
  let win = sendLastWindow()
  if win.exe.len == 0 and win.title.len == 0:
    echo "Daemon has not seen any window activation yet."
    echo "Is the KWin watcher script enabled and reloaded?"
    echo "    ./bin/vw_autofill install-kwin-script"
    quit 1
  echo "Captured:"
  echo "  exe   = ", win.exe
  echo "  title = ", win.title
  echo "  class = ", win.cls
  echo ""

  var labels: seq[string]
  for i, name in items.names:
    let id = items.ids[i]
    let shortId = if id.len >= 8: id[0 ..< 8] else: id
    labels.add name & "  [" & shortId & "]"
  let pickedLabel = fzfPick("Vault item to attach URI to", labels)
  if pickedLabel.len == 0:
    echo "cancelled"
    quit 1
  var pickedId = ""
  var pickedName = ""
  for i, l in labels:
    if l == pickedLabel:
      pickedId = items.ids[i]
      pickedName = items.names[i]
      break

  let seqStr     = promptDefault("Sequence", "$user$tab$pass")
  let titleMatch = promptDefault("Title substring matcher (empty = none)", "")
  let useClass   = fzfPick("Add class matcher?", ["no", "yes"]) == "yes"
  let modeStr    = fzfPick("Mode", ["hotkey", "auto"])

  var qparts: seq[string]
  if titleMatch.len > 0:
    qparts.add "title=" & encodeUrl(titleMatch, usePlus = false)
  if useClass:
    qparts.add "class=" & encodeUrl(win.cls, usePlus = false)
  qparts.add "seq=" & encodeUrl(seqStr, usePlus = false)
  if modeStr == "auto":
    qparts.add "mode=auto"
    if titleMatch.len == 0 and not useClass:
      qparts.add "unsafe=1"
  let q = if qparts.len > 0: "?" & qparts.join("&") else: ""
  let uriStr = "linapp://" & win.exe & q

  echo ""
  echo "URI:  ", uriStr
  echo "Item: ", pickedName, " (", pickedId, ")"
  echo ""

  sendAddUriToItem(pickedId, uriStr)
  echo "saved to vault; daemon rules refreshed."

proc usage() =
  echo """vw-autofill — Bitwarden/Vaultwarden desktop autofill

Usage:
    vw-autofill <command> [args...]

Commands:
    list                  list every rule URI in your unlocked vault
    status                print bw vault status JSON
    daemon                run the session-bus daemon (auto-unlocks if foreground)
    unlock                explicit interactive unlock + persist session
    fill                  tell a running daemon to fire its cached match
    reload                tell a running daemon to re-fetch rules from bw
    capture               interactive rule builder for the focused window
    install-kwin-script   install + enable the KWin watcher script
    uninstall-kwin-script remove the KWin watcher script
    introspect            fetch the daemon's introspection XML
    simulate EXE TITLE [CLASS] [PID]
                          synthesize a WindowActivated D-Bus call
    help                  this message

Environment:
    BW_SESSION       required for list/status/daemon
    YDOTOOL_SOCKET   override ydotool socket path (default $1)
    VW_AUTOFILL_LOG  if set, daemon also appends events to this path
""" % DefaultYdotoolSocket

when isMainModule:
  if paramCount() == 0:
    usage()
    quit 1
  case paramStr(1)
  of "list":       cmdList()
  of "status":     cmdStatus()
  of "daemon":     cmdDaemon()
  of "fill":       cmdFill()
  of "unlock":     cmdUnlock()
  of "reload":     cmdReload()
  of "capture":    cmdCapture()
  of "install-kwin-script":   cmdInstallKwinScript()
  of "uninstall-kwin-script": cmdUninstallKwinScript()
  of "introspect": cmdIntrospect()
  of "simulate":   cmdSimulate()
  of "help", "--help", "-h": usage()
  else:
    stderr.writeLine "unknown command: " & paramStr(1)
    usage()
    quit 1
