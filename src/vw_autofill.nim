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

import std/[os, json, strutils]
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

proc cmdDaemon() =
  let session = getEnv("BW_SESSION")
  let b = newBwBackend(session)
  let rules = b.collectRules()
  let socket = getEnv("YDOTOOL_SOCKET", DefaultYdotoolSocket)
  let logPath = getEnv("VW_AUTOFILL_LOG")
  let d = newDaemon(rules, socket, logPath)
  d.serve()

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

proc usage() =
  echo """vw-autofill — Bitwarden/Vaultwarden desktop autofill

Usage:
    vw-autofill <command> [args...]

Commands:
    list                  list every rule URI in your unlocked vault
    status                print bw vault status JSON
    daemon                run the session-bus daemon (needs BW_SESSION)
    fill                  tell a running daemon to fire its cached match
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
  of "introspect": cmdIntrospect()
  of "simulate":   cmdSimulate()
  of "help", "--help", "-h": usage()
  else:
    stderr.writeLine "unknown command: " & paramStr(1)
    usage()
    quit 1
