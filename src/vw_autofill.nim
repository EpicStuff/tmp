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
  except Exception as e:
    ## nim-dbus's DbusException inherits straight from Exception, not
    ## CatchableError -- so `except CatchableError` would let it propagate
    ## and print a stack trace instead of our friendly message.
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

proc step(ok: bool, msg: string) =
  let mark = if ok: "[ok]  " else: "[fail]"
  echo mark & " " & msg

proc findKdeTool(names: openArray[string]): string =
  ## Different distros ship different binary names for the Qt6 helpers
  ## (qdbus6 / qdbus-qt6 / qdbus, kpackagetool6 / kf6-kpackagetool, ...).
  ## Pick the first that's on PATH.
  for n in names:
    if findExe(n).len > 0: return n
  return ""

proc kwinDbusCall(qdbus, busctl, service, path, iface, meth: string,
                  args: openArray[string] = []): tuple[output: string, code: int] =
  ## Prefer qdbus (matches everything we read in docs / blog posts).
  ## Fall back to busctl when qdbus6/qdbus-qt6/qdbus isn't installed --
  ## busctl is part of systemd and present basically everywhere.
  if qdbus.len > 0:
    var cmd = qdbus & " " & service & " " & path & " " & iface & "." & meth
    for a in args: cmd.add(" " & quoteShell(a))
    return runCheck(cmd)
  if busctl.len > 0:
    var cmd = busctl & " --user call " & service & " " & path & " " &
              iface & " " & meth
    for a in args: cmd.add(" " & quoteShell(a))
    return runCheck(cmd)
  return ("(no qdbus or busctl available)", 127)

proc installedScriptPath(): string =
  getHomeDir() / ".local/share/kwin/scripts/vw-autofill-watcher/contents/code/main.js"

proc cmdInstallKwinScript() =
  ## End-to-end KWin script installer + verifier.
  ##
  ## Each step prints [ok]/[fail]. After the reload, polls the daemon
  ## log for "[kwin-script]" entries -- which is the only reliable proof
  ## that KWin actually started running the new script. (Plasma 6 caches
  ## script bytecode aggressively; the file can be on disk and the
  ## plugin "enabled" without the new code ever loading.)
  let src = findKwinScriptSource()
  if src.len == 0:
    stderr.writeLine "[fail] could not find data/kwin-script next to the binary"
    quit 1
  echo "source:    ", src
  let logPath = getEnv("VW_AUTOFILL_LOG", "/tmp/vw-autofill-daemon.log")
  echo "log:       ", logPath

  # Locate KDE helpers; report missing ones up front so the user knows
  # what to install if a step fails.
  let kpackage    = findKdeTool(["kpackagetool6", "kf6-kpackagetool", "kpackagetool"])
  let kwriteconf  = findKdeTool(["kwriteconfig6", "kf6-kwriteconfig", "kwriteconfig5"])
  let qdbus       = findKdeTool(["qdbus6", "qdbus-qt6", "qdbus"])
  let busctl      = findExe("busctl")
  step(kpackage.len > 0,   "kpackagetool: " & (if kpackage.len > 0: kpackage else: "MISSING (install plasma-workspace)"))
  step(kwriteconf.len > 0, "kwriteconfig: " & (if kwriteconf.len > 0: kwriteconf else: "MISSING (install kconfig)"))
  step(qdbus.len > 0 or busctl.len > 0,
       "dbus client:  " & (if qdbus.len > 0: qdbus elif busctl.len > 0: busctl & " (qdbus6 not found)" else: "MISSING"))
  if kpackage.len == 0 or kwriteconf.len == 0 or (qdbus.len == 0 and busctl.len == 0):
    quit 1

  # If the daemon isn't on the bus, the [kwin-script] log entries won't
  # be captured -- still install, but warn so the diagnostic at the end
  # is interpreted correctly.
  let (busOut, _) = runCheck(busctl & " --user list 2>/dev/null")
  let daemonUp = "org.vwautofill.Daemon" in busOut
  step(daemonUp, "daemon on bus: " &
       (if daemonUp: "yes" else: "NO (script load diagnostic won't appear in log)"))

  # 1. Remove any prior install so Plasma can't reuse cached bytecode.
  let (_, _) = runCheck(kpackage & " -t KWin/Script -r vw-autofill-watcher")

  # 2. Fresh install.
  let (iOut, iCode) = runCheck(
    kpackage & " -t KWin/Script -i " & quoteShell(src))
  step(iCode == 0, "kpackagetool install" &
       (if iCode != 0: " -- " & iOut.strip else: ""))
  if iCode != 0: quit 1

  # 3. Verify the file actually landed.
  let dst = installedScriptPath()
  let fileLanded = fileExists(dst)
  step(fileLanded, "installed file: " & dst)
  if not fileLanded: quit 1

  # 4. Sanity: installed file matches source (catches stale-package weirdness).
  let srcMain = src / "contents" / "code" / "main.js"
  if fileExists(srcMain) and fileLanded:
    let same = readFile(srcMain) == readFile(dst)
    step(same, "installed file matches source")

  # 5. Enable in kwinrc.
  let (eOut, eCode) = runCheck(kwriteconf & " --file kwinrc --group Plugins " &
                               "--key vw-autofill-watcherEnabled true")
  step(eCode == 0, "kwinrc Plugins/vw-autofill-watcherEnabled = true" &
       (if eCode != 0: " -- " & eOut.strip else: ""))

  # 6. Tell KWin to re-read config (picks up the enable). On Plasma 6
  # this is the canonical way to load/unload scripts; Scripting.start
  # alone won't pick up a freshly-enabled script reliably.
  let (rcOut, rcCode) = kwinDbusCall(
    qdbus, busctl, "org.kde.KWin", "/KWin", "org.kde.KWin", "reconfigure")
  step(rcCode == 0, "KWin reconfigure" &
       (if rcCode != 0: " -- " & rcOut.strip else: ""))

  # 7. Belt-and-braces: also poke Scripting.start in case reconfigure
  # didn't trigger a script-engine restart on this KWin version.
  let (sOut, sCode) = kwinDbusCall(
    qdbus, busctl, "org.kde.KWin", "/Scripting", "org.kde.kwin.Scripting", "start")
  step(sCode == 0, "Scripting.start" &
       (if sCode != 0: " -- " & sOut.strip else: ""))

  # 8. Diagnostic: wait up to 3s for "[kwin-script]" to show up in the
  # daemon log. If it doesn't, the script almost certainly didn't load.
  echo ""
  echo "waiting up to 3s for the script to phone home..."
  let logSizeBefore = if fileExists(logPath): getFileSize(logPath) else: 0
  var scriptPhonedHome = false
  for i in 0 .. 15:
    sleep(200)
    if fileExists(logPath):
      let f = open(logPath, fmRead)
      defer: f.close()
      f.setFilePos(logSizeBefore)
      let tail = f.readAll()
      if "[kwin-script]" in tail:
        scriptPhonedHome = true
        echo ""
        echo "--- new [kwin-script] entries: ---"
        for line in tail.splitLines:
          if "[kwin-script]" in line: echo line
        break

  echo ""
  if scriptPhonedHome:
    step(true, "script loaded and called daemon.Log()")
    echo ""
    echo "Default Fill shortcut: Meta+Alt+V."
    echo "Rebind in System Settings -> Shortcuts (search 'vw-autofill')."
  else:
    step(false, "no [kwin-script] entries in " & logPath & " after 3s")
    echo ""
    echo "The package is on disk and enabled but KWin doesn't seem to have"
    echo "loaded it. Things to try:"
    echo "  1. Make sure the daemon is running first, then re-run this command."
    echo "     (without the daemon, Log() calls go nowhere -- the script may"
    echo "      have loaded just fine, we just couldn't observe it.)"
    echo "  2. Log out of your Plasma session and back in. KWin re-reads"
    echo "     scripts on session start; mid-session reload is flaky."
    echo "  3. If you're on X11 instead of Wayland: kwin_x11 --replace &"
    echo "     (Wayland equivalent requires logging out.)"

proc cmdUninstallKwinScript() =
  let kpackage   = findKdeTool(["kpackagetool6", "kf6-kpackagetool", "kpackagetool"])
  let kwriteconf = findKdeTool(["kwriteconfig6", "kf6-kwriteconfig", "kwriteconfig5"])
  let qdbus      = findKdeTool(["qdbus6", "qdbus-qt6", "qdbus"])
  let busctl     = findExe("busctl")
  if kpackage.len == 0:
    stderr.writeLine "[fail] kpackagetool6 not found"
    quit 1

  let (rmOut, rmCode) = runCheck(kpackage & " -t KWin/Script -r vw-autofill-watcher")
  step(rmCode == 0, "kpackagetool remove" &
       (if rmCode != 0: " -- " & rmOut.strip else: ""))

  if kwriteconf.len > 0:
    discard runCheck(kwriteconf & " --file kwinrc --group Plugins " &
                     "--key vw-autofill-watcherEnabled false")
    step(true, "kwinrc Plugins/vw-autofill-watcherEnabled = false")

  discard kwinDbusCall(qdbus, busctl, "org.kde.KWin", "/KWin",
                       "org.kde.KWin", "reconfigure")
  step(true, "KWin reconfigure")

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
  requireDaemon()
  let n = sendReload()
  echo "reloaded: ", n, " rule(s)"

proc cmdFill() =
  requireDaemon()
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
  requireDaemon()
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
  requireDaemon()
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
  requireDaemon()

  var items: tuple[ids, names: seq[string]]
  try:
    items = sendListItems()
  except Exception as e:
    ## nim-dbus exceptions inherit from Exception, not CatchableError
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
