## vw-autofill — entry point.
##
## Subcommands:
##   list     dump every matchable rule the vault exposes
##   status   report bw vault status
##   daemon   run the session-bus daemon (KWin script + hotkey call into it)
##   fill     tell the running daemon to fire its cached match
##   unlock   prompt for master password + push token to a running daemon
##   help     this message

import std/[os, json, strutils, uri, osproc, streams, posix]
import vw_autofill/[vault, rule, daemon, typing]

proc isForeground(): bool =
  ## True iff stdin's terminal foreground process group is us. False
  ## when we're a backgrounded job (`./bin/vw_autofill daemon &`),
  ## meaning any attempt to read from /dev/tty for a password prompt
  ## would get SIGTTIN'd and hang forever.
  let fg = tcgetpgrp(0.cint)
  if fg == -1: return false  ## no controlling terminal at all
  return fg == getpgrp()

proc spawnUnlockTerminal(): bool =
  ## Pop open a terminal running `./bin/vw_autofill unlock`. Used by
  ## cmdDaemon when it needs the master password but can't prompt
  ## itself. Returns true if a terminal was launched.
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

proc runCheck(cmd: string): tuple[output: string, code: int] =
  let r = execCmdEx(cmd)
  (r.output, r.exitCode)

proc step(ok: bool, msg: string) =
  let mark = if ok: "[ok]  " else: "[fail]"
  echo mark & " " & msg

proc findRepoLayout(): tuple[monitor, kglobalaccelDesktop: string] =
  ## Resolve the bin/vw-window-monitor and share/kglobalaccel/vw-autofill.desktop
  ## paths relative to this binary. Repo layout: <repo>/bin/vw_autofill +
  ## <repo>/bin/vw-window-monitor + <repo>/share/kglobalaccel/vw-autofill.desktop.
  let exeDir = getAppFilename().parentDir
  let repoRoot = exeDir.parentDir
  result.monitor = repoRoot / "bin" / "vw-window-monitor"
  result.kglobalaccelDesktop = repoRoot / "share" / "kglobalaccel" / "vw-autofill.desktop"

proc kglobalaccelDestDir(): string =
  getHomeDir() / ".local/share/kglobalaccel"

proc autostartDestDir(): string =
  getHomeDir() / ".config/autostart"

proc autostartDesktopBody(monitorPath: string): string =
  ## XDG autostart entry that spawns vw-window-monitor on session login.
  ## Uses the absolute path to the Python script so PATH order can't
  ## resolve a stale copy.
  "[Desktop Entry]\n" &
  "Type=Application\n" &
  "Name=vw-autofill window monitor\n" &
  "Comment=Forward KWin window-activation events to the vw-autofill daemon\n" &
  "Exec=" & monitorPath & "\n" &
  "X-GNOME-Autostart-enabled=true\n" &
  "OnlyShowIn=KDE;\n" &
  "NoDisplay=true\n"

proc symlinkOrCopy(src, dst: string): bool =
  ## Symlink if possible; copy as a fallback (some filesystems don't
  ## support symlinks). Returns true on success.
  try:
    removeFile(dst)
  except OSError, IOError:
    discard
  try:
    createSymlink(src, dst)
    return true
  except OSError, IOError:
    try:
      copyFile(src, dst)
      return true
    except OSError, IOError:
      return false

proc cmdInstall() =
  ## Install the window-monitor + the .desktop file kglobalacceld picks
  ## up to wire Meta+Alt+V to the daemon's Fill() method.
  ##
  ## Symlinks (or copies, if the FS rejects symlinks):
  ##   <repo>/share/kglobalaccel/vw-autofill.desktop ->
  ##       ~/.local/share/kglobalaccel/vw-autofill.desktop
  ##   autostart shim runs <repo>/bin/vw-window-monitor on session login:
  ##       ~/.config/autostart/vw-autofill-window-monitor.desktop
  let layout = findRepoLayout()

  step(fileExists(layout.monitor),
       "monitor source: " & layout.monitor)
  step(fileExists(layout.kglobalaccelDesktop),
       ".desktop source: " & layout.kglobalaccelDesktop)
  if not fileExists(layout.monitor) or not fileExists(layout.kglobalaccelDesktop):
    quit 1

  # Verify the Python deps the monitor needs at runtime. Catch this up
  # front instead of as a confusing autostart failure later.
  let pyCheck = "python3 -c " & quoteShell(
    "import dbus, dbus.mainloop.glib, gi.repository.GLib")
  let (pcOut, pcCode) = runCheck(pyCheck & " 2>&1")
  step(pcCode == 0, "python3 deps (dbus, gi.repository.GLib): " &
       (if pcCode == 0: "ok" else: "MISSING -- " & pcOut.strip))
  if pcCode != 0:
    echo ""
    echo "Install with: sudo pacman -S python-dbus python-gobject"
    quit 1

  let kglobalaccelDst = kglobalaccelDestDir() / "vw-autofill.desktop"
  createDir(kglobalaccelDestDir())
  let okKga = symlinkOrCopy(layout.kglobalaccelDesktop, kglobalaccelDst)
  step(okKga, kglobalaccelDst)
  if not okKga: quit 1

  let autostartDst = autostartDestDir() / "vw-autofill-window-monitor.desktop"
  createDir(autostartDestDir())
  writeFile(autostartDst, autostartDesktopBody(layout.monitor))
  step(fileExists(autostartDst), autostartDst)

  # Nudge kglobalacceld to rescan the kglobalaccel/ directory. If the
  # service isn't running yet (rare), the .desktop will be picked up on
  # next session start regardless.
  let busctl = findExe("busctl")
  if busctl.len > 0:
    discard runCheck(busctl & " --user call org.kde.kglobalaccel " &
                     "/kglobalaccel org.kde.KGlobalAccel reloadComponent " &
                     "vw-autofill.desktop 2>/dev/null")

  echo ""
  echo "Window monitor and shortcut installed. To start the monitor now"
  echo "without logging out and back in:"
  echo "    nohup " & layout.monitor & " >/tmp/vw-window-monitor.log 2>&1 &"
  echo ""
  echo "Default Fill shortcut: Meta+Alt+V (rebind in System Settings ->"
  echo "Shortcuts, search 'vw-autofill')."

proc cmdUninstall() =
  let kglobalaccelDst = kglobalaccelDestDir() / "vw-autofill.desktop"
  let autostartDst    = autostartDestDir() / "vw-autofill-window-monitor.desktop"
  for p in [kglobalaccelDst, autostartDst]:
    if fileExists(p) or symlinkExists(p):
      try:
        removeFile(p)
        step(true, "removed " & p)
      except CatchableError as e:
        step(false, "remove " & p & ": " & e.msg)
    else:
      step(true, "not present: " & p)

  let pidf = runCheck("pgrep -f vw-window-monitor 2>/dev/null")
  if pidf.code == 0 and pidf.output.strip.len > 0:
    echo ""
    echo "vw-window-monitor is still running. To stop it now:"
    echo "    pkill -f vw-window-monitor"

proc warnIfNoYdotoold(socket: string) =
  if not fileExists(socket):
    stderr.writeLine "WARNING: ydotoold socket " & socket &
      " not present. Fill will fail to type until you start ydotoold:"
    stderr.writeLine "    sudo ydotoold --socket-path=" & socket &
      " --socket-perm=0666"

proc cmdDaemon() =
  ## Resolve a working session, or fall back to a locked-state startup
  ## where the daemon serves on the bus but holds no backend until
  ## someone (typically a spawned `vw-autofill unlock` terminal)
  ## delivers a session token via the UnlockWith D-Bus method.
  var backend: BwBackend = nil
  var rules: seq[BoundRule]

  proc trySession(s, label: string): bool =
    if s.len == 0: return false
    try:
      let b = newBwBackend(s)
      rules = b.collectRules()  # validate + capture in one shot
      backend = b
      stderr.writeLine "vault: using " & label
      return true
    except CatchableError as e:
      stderr.writeLine "vault: " & label & " is stale (" & e.msg & ")"
      return false

  discard trySession(getEnv("BW_SESSION"), "BW_SESSION env")

  if backend == nil:
    if isForeground():
      let token = bwUnlockInteractive()
      if not trySession(token, "fresh unlock"):
        stderr.writeLine "could not load vault even after fresh unlock"
        quit 1
    else:
      # Backgrounded / autostarted: can't prompt ourselves. Spawn
      # a terminal running `vw-autofill unlock`; it'll deliver the
      # token over D-Bus once the user types their password. We
      # meanwhile serve on the bus in locked state.
      if not spawnUnlockTerminal():
        stderr.writeLine "No terminal emulator found."
        stderr.writeLine "Run `./bin/vw_autofill unlock` in a foreground shell."
        quit 1
      stderr.writeLine "Daemon starting in locked state; waiting for unlock terminal."

  let socket = getEnv("YDOTOOL_SOCKET", DefaultYdotoolSocket)
  let logPath = getEnv("VW_AUTOFILL_LOG", "/tmp/vw-autofill-daemon.log")
  warnIfNoYdotoold(socket)
  let d = newDaemon(backend, rules, socket, logPath)
  d.serve()

proc cmdReload() =
  requireDaemon()
  let n = sendReload()
  echo "reloaded: ", n, " rule(s)"

proc cmdFill() =
  requireDaemon()
  sendFill()

proc cmdUnlock() =
  ## Prompt for the master password, run `bw unlock --raw`, and push
  ## the resulting session token to a running daemon over D-Bus.
  if not isForeground():
    stderr.writeLine "unlock needs a foreground shell (it prompts for the master password)"
    quit 1
  let token = bwUnlockInteractive()
  try:
    let n = sendUnlockWith(token)
    echo "daemon unlocked: ", n, " rule(s)"
  except Exception as e:
    stderr.writeLine "could not deliver token to daemon: " & e.msg
    stderr.writeLine "Start the daemon first: ./bin/vw_autofill daemon"
    quit 1

proc cmdIntrospect() =
  ## Talk to the running daemon via the same nim-dbus library it serves
  ## with — bypasses busctl's introspect quirks.
  requireDaemon()
  echo sendIntrospect()

proc cmdSimulate() =
  ## Synthesize a WindowActivated call to the daemon. Useful for testing
  ## the matcher path without a live window monitor.
  ##   vw-autofill simulate <exe> <title> [class]
  if paramCount() < 3:
    stderr.writeLine "usage: vw-autofill simulate <exe> <title> [class]"
    quit 1
  let exe   = paramStr(2)
  let title = paramStr(3)
  let cls   = if paramCount() >= 4: paramStr(4) else: ""
  requireDaemon()
  sendWindowActivated(exe, title, cls)
  echo "sent WindowActivated(exe=", exe, ", title=", title,
       ", class=", cls, ")"

proc promptDefault(prompt, default: string): string =
  stdout.write(prompt)
  if default.len > 0: stdout.write(" [" & default & "]")
  stdout.write(": ")
  stdout.flushFile()
  let line = readLine(stdin).strip()
  if line.len == 0: default else: line

proc fzfPick(prompt: string, choices: openArray[string]): string =
  ## Show `choices` in fzf. Empty result means the user cancelled
  ## (esc / no selection). fzf is required — install it via your
  ## package manager if missing.
  if findExe("fzf").len == 0:
    stderr.writeLine "fzf is required for the capture flow; install fzf and retry"
    quit 1
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
    echo "Is the window monitor running?"
    echo "    ./bin/vw_autofill install"
    echo "    nohup ./bin/vw-window-monitor >/tmp/vw-window-monitor.log 2>&1 &"
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
    unlock                prompt + push session token to running daemon
    fill                  tell a running daemon to fire its cached match
    reload                tell a running daemon to re-fetch rules from bw
    capture               interactive rule builder for the focused window
    install              install vw-window-monitor + Meta+Alt+V .desktop
    uninstall            remove the above
    introspect            fetch the daemon's introspection XML
    simulate EXE TITLE [CLASS]
                          synthesize a WindowActivated D-Bus call
    help                  this message

Environment:
    BW_SESSION       optional; daemon will validate it on startup
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
  of "install":   cmdInstall()
  of "uninstall": cmdUninstall()
  of "introspect": cmdIntrospect()
  of "simulate":   cmdSimulate()
  of "help", "--help", "-h": usage()
  else:
    stderr.writeLine "unknown command: " & paramStr(1)
    usage()
    quit 1
