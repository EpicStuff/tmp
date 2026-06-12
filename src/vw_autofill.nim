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

import std/[os, json, strutils, uri, osproc, streams]
import vw_autofill/[vault, rule, daemon, linux_consts]

proc cmdStatus() =
  let session = getEnv("BW_SESSION")
  let b = newBwBackend(session)
  let s = b.status()
  echo s.pretty

proc cmdList() =
  let session = getEnv("BW_SESSION")
  let b = newBwBackend(session)
  let rules = b.collectRules()
  if rules.len == 0:
    echo "no vw-autofill rules found"
    return
  for br in rules:
    let r = br.rule
    let scheme = ($r.scheme)
    let exeRepr = if r.exe.len == 0: "<empty>" else: r.exe
    echo scheme & "://" & exeRepr,
      "  item=", br.credential.itemName,
      "  mode=", $r.mode,
      (if r.title.len > 0: "  title=" & r.title else: ""),
      (if r.class.len > 0: "  class=" & r.class else: "")

proc readBwSession(): string =
  ## Get a vault session token. Priority:
  ##   1. BW_SESSION env if non-empty
  ##   2. spawn `bw unlock --raw` interactively
  ## bw's password prompt goes to /dev/tty directly (Node inquirer),
  ## so we just need to capture stdout for the session token.
  let env = getEnv("BW_SESSION")
  if env.len > 0:
    return env
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

proc warnIfNoYdotoold(socket: string) =
  if not fileExists(socket):
    stderr.writeLine "WARNING: ydotoold socket " & socket &
      " not present. Fill will fail to type until you start ydotoold:"
    stderr.writeLine "    sudo ydotoold --socket-path=" & socket &
      " --socket-perm=0666"

proc cmdDaemon() =
  let session = readBwSession()
  let b = newBwBackend(session)
  let rules = b.collectRules()
  let socket = getEnv("YDOTOOL_SOCKET", DefaultYdotoolSocket)
  let logPath = getEnv("VW_AUTOFILL_LOG", "/tmp/vw-autofill-daemon.log")
  warnIfNoYdotoold(socket)
  let d = newDaemon(rules, socket, logPath)
  let backend = b
  d.reloadProc = proc(): seq[BoundRule] = backend.collectRules()
  d.serve()

proc cmdReload() =
  let n = sendReload()
  echo "reloaded: ", n, " rule(s)"

proc cmdFill() =
  sendFill()

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
  ## Interactive rule-creation flow.
  ##   1. countdown so user can focus the target window
  ##   2. fetch lastWindow from daemon
  ##   3. fzf-pick the vault item to attach the URI to
  ##   4. prompt for sequence / matchers / mode
  ##   5. push URI into the vault item via bw edit
  ##   6. tell the daemon to reload — no manual restart
  let session = getEnv("BW_SESSION")
  if session.len == 0:
    stderr.writeLine "BW_SESSION required"
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
    echo "Is the daemon running and is the KWin watcher script enabled?"
    quit 1
  echo "Captured:"
  echo "  exe   = ", win.exe
  echo "  title = ", win.title
  echo "  class = ", win.cls
  echo ""

  # Pick vault item via fzf. Label is "<name>  [<short-id>]" so the
  # user can disambiguate items with duplicate names.
  let b = newBwBackend(session)
  let creds = b.listLogins()
  if creds.len == 0:
    echo "no login items in vault"
    quit 1
  var labels: seq[string]
  for c in creds:
    let shortId = if c.itemId.len >= 8: c.itemId[0 ..< 8] else: c.itemId
    labels.add c.itemName & "  [" & shortId & "]"
  let pickedLabel = fzfPick("Vault item to attach URI to", labels)
  if pickedLabel.len == 0:
    echo "cancelled"
    quit 1
  var pickedId = ""
  var pickedName = ""
  for i, l in labels:
    if l == pickedLabel:
      pickedId = creds[i].itemId
      pickedName = creds[i].itemName
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
    # auto without any matcher needs unsafe=1 to pass isSafe
    if titleMatch.len == 0 and not useClass:
      qparts.add "unsafe=1"
  let q = if qparts.len > 0: "?" & qparts.join("&") else: ""
  let uriStr = "linapp://" & win.exe & q

  echo ""
  echo "URI:  ", uriStr
  echo "Item: ", pickedName, " (", pickedId, ")"
  echo ""

  bwAddUriToItem(pickedId, uriStr, session)
  echo "saved to vault."

  try:
    let n = sendReload()
    echo "daemon reloaded: ", n, " rule(s) total."
  except CatchableError as e:
    echo "saved, but daemon reload failed: ", e.msg
    echo "(run `vw_autofill reload` manually once the daemon is up)"

proc usage() =
  echo """vw-autofill — Bitwarden/Vaultwarden desktop autofill

Usage:
    vw-autofill <command> [args...]

Commands:
    list                  list every rule URI in your unlocked vault
    status                print bw vault status JSON
    daemon                run the session-bus daemon (needs BW_SESSION)
    fill                  tell a running daemon to fire its cached match
    reload                tell a running daemon to re-fetch rules from bw
    capture               interactive rule builder for the focused window
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
  of "reload":     cmdReload()
  of "capture":    cmdCapture()
  of "introspect": cmdIntrospect()
  of "simulate":   cmdSimulate()
  of "help", "--help", "-h": usage()
  else:
    stderr.writeLine "unknown command: " & paramStr(1)
    usage()
    quit 1
