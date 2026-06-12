## Session-bus daemon. Owns org.vwautofill.Daemon at path
## /org/vwautofill/Daemon. Two methods:
##
##   WindowActivated(s exe, s title, s class, u pid)
##     Called by the KWin script whenever focus changes. We update
##     our cached `lastWindow` + recompute the best matching rule.
##
##   Fill()
##     Called by the hotkey wrapper. We play the cached match's
##     sequence through ydotool. No reply args.

import std/[os, options]
import dbus
import dbus/lowlevel
import ./[rule, match, typing, linux_consts]

const
  BusName*    = "org.vwautofill.Daemon"
  ObjPath*    = "/org/vwautofill/Daemon"
  IfaceName*  = "org.vwautofill.Daemon1"
  IntroIface* = "org.freedesktop.DBus.Introspectable"

const introspectionXml = """<!DOCTYPE node PUBLIC "-//freedesktop//DTD D-BUS Object Introspection 1.0//EN"
  "http://www.freedesktop.org/standards/dbus/1.0/introspect.dtd">
<node>
  <interface name="org.vwautofill.Daemon1">
    <method name="WindowActivated">
      <arg type="s" name="exe"   direction="in"/>
      <arg type="s" name="title" direction="in"/>
      <arg type="s" name="class" direction="in"/>
      <arg type="u" name="pid"   direction="in"/>
    </method>
    <method name="Fill"/>
  </interface>
  <interface name="org.freedesktop.DBus.Introspectable">
    <method name="Introspect">
      <arg type="s" name="data" direction="out"/>
    </method>
  </interface>
</node>
"""

type
  Daemon* = ref object
    bus*: Bus
    rules*: seq[BoundRule]
    lastWindow*: WindowInfo
    lastMatch*: Option[BoundRule]
    socket*: string
    logf*: File

proc log(d: Daemon, line: string) =
  ## Single sink for human-readable status. Stderr by default; if
  ## VW_AUTOFILL_LOG is set we tee there too so journalctl picks it up.
  stderr.writeLine line
  if d.logf != nil:
    d.logf.writeLine line
    d.logf.flushFile()

proc recomputeMatch(d: Daemon) =
  d.lastMatch = none(BoundRule)
  for br in d.rules:
    if br.rule.matches(d.lastWindow, platformIsLinux = true):
      d.lastMatch = some(br)
      return

proc handleWindowActivated(d: Daemon, args: seq[DbusValue]): bool =
  if args.len < 4:
    d.log "WindowActivated: bad arg count " & $args.len
    return false
  let exe   = args[0].asNative(string)
  let title = args[1].asNative(string)
  let cls   = args[2].asNative(string)
  let pid   = args[3].asNative(uint32)
  d.lastWindow = WindowInfo(
    exePath: exe,
    exeName: extractFilename(exe),
    title: title,
    class: cls,
    text: "",
  )
  d.recomputeMatch()
  let label =
    if d.lastMatch.isSome: "match=" & d.lastMatch.get.credential.itemName
    else: "no match"
  d.log "activated pid=" & $pid & " class=" & cls & " title=" & title & " -> " & label
  true

proc handleFill(d: Daemon): bool =
  if d.lastMatch.isNone:
    d.log "Fill: no cached match, ignoring"
    return true
  let br = d.lastMatch.get
  let seqStr = if br.rule.sequence.len > 0: br.rule.sequence else: DefaultSequence
  d.log "Fill: playing " & seqStr & " for item=" & br.credential.itemName
  try:
    playSequence(seqStr, br.credential, d.socket)
  except CatchableError as e:
    d.log "Fill: typing failed: " & e.msg
  true

proc handleIntrospect(d: Daemon, bus: Bus, incoming: IncomingMessage): bool =
  bus.sendReply(incoming, @[asDbusValue(introspectionXml)])
  true

proc makeCallback(d: Daemon): MessageCallback =
  result = proc(kind: IncomingMessageType, incoming: IncomingMessage): bool =
    let iface = incoming.interfaceName
    let name  = incoming.name
    if iface == IfaceName:
      case name
      of "WindowActivated":
        let args = incoming.unpackValueSeq()
        let ok = d.handleWindowActivated(args)
        d.bus.sendReply(incoming, @[])
        return ok
      of "Fill":
        discard d.handleFill()
        d.bus.sendReply(incoming, @[])
        return true
      else:
        d.bus.sendErrorReply(incoming, "unknown method " & name)
        return true
    elif iface == IntroIface and name == "Introspect":
      return d.handleIntrospect(d.bus, incoming)
    else:
      return false  ## let other handlers (e.g. peer ping) deal with it

proc newDaemon*(rules: seq[BoundRule], socket = DefaultYdotoolSocket,
                logPath = ""): Daemon =
  result = Daemon(rules: rules, socket: socket, lastMatch: none(BoundRule))
  if logPath.len > 0:
    result.logf = open(logPath, fmAppend)

proc serve*(d: Daemon) =
  d.bus = getBus(DBUS_BUS_SESSION)
  d.bus.requestName(BusName)
  d.bus.registerObject(ObjPath.ObjectPath, makeCallback(d))
  d.log "vw-autofill daemon listening on " & BusName & " path " & ObjPath
  d.log "loaded " & $d.rules.len & " rule(s)"
  while dbus_connection_read_write_dispatch(d.bus.conn, -1) == 1:
    discard

proc sendFill*() =
  ## Client side: tell a running daemon to fire its cached match.
  let bus = getBus(DBUS_BUS_SESSION)
  var msg = makeCall(BusName, ObjPath.ObjectPath, IfaceName, "Fill")
  let pending = bus.sendMessageWithReply(msg)
  let reply = pending.waitForReply()
  defer: reply.close()
  reply.raiseIfError()
