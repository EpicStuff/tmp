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
    d.log "recv kind=" & $kind & " iface='" & iface & "' name='" & name & "'"
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
    # Introspect can arrive with iface = "" (some clients omit it).
    elif name == "Introspect" and (iface == IntroIface or iface.len == 0):
      return d.handleIntrospect(d.bus, incoming)
    # Standard Peer interface so busctl status / ping works.
    elif iface == "org.freedesktop.DBus.Peer":
      case name
      of "Ping":
        d.bus.sendReply(incoming, @[])
        return true
      of "GetMachineId":
        d.bus.sendReply(incoming, @[asDbusValue("00000000000000000000000000000000")])
        return true
      else: discard
    d.log "  -> no handler matched, replying error"
    d.bus.sendErrorReply(incoming,
      "no handler for " & iface & "." & name)
    return true

proc newDaemon*(rules: seq[BoundRule], socket = DefaultYdotoolSocket,
                logPath = ""): Daemon =
  result = Daemon(rules: rules, socket: socket, lastMatch: none(BoundRule))
  if logPath.len > 0:
    result.logf = open(logPath, fmAppend)

const
  DBUS_NAME_FLAG_ALLOW_REPLACEMENT = 0x1.cuint
  DBUS_NAME_FLAG_REPLACE_EXISTING  = 0x2.cuint
  DBUS_NAME_FLAG_DO_NOT_QUEUE      = 0x4.cuint
  REQUEST_NAME_REPLY_PRIMARY_OWNER = 1
  REQUEST_NAME_REPLY_ALREADY_OWNER = 4

proc claimNameOrDie(d: Daemon, name: string) =
  ## nim-dbus's requestName calls libdbus with flags=0 and doesn't
  ## verify ownership. If a stale daemon (or anyone) already owns the
  ## name, the new process silently isn't the owner, and the bus
  ## routes calls to whoever the bus still considers the owner. Force
  ## replacement and abort if we can't become primary.
  var err: DBusError
  dbus_error_init(addr err)
  let flags = DBUS_NAME_FLAG_REPLACE_EXISTING or
              DBUS_NAME_FLAG_ALLOW_REPLACEMENT or
              DBUS_NAME_FLAG_DO_NOT_QUEUE
  let ret = dbus_bus_request_name(d.bus.conn, name, flags, addr err)
  if ret < 0:
    defer: dbus_error_free(addr err)
    raise newException(DbusException, $err.message)
  if ret != REQUEST_NAME_REPLY_PRIMARY_OWNER and
     ret != REQUEST_NAME_REPLY_ALREADY_OWNER:
    raise newException(DbusException,
      "could not claim " & name & " (reply=" & $ret & ")")
  d.log "claimed bus name " & name & " (reply=" & $ret & ")"

proc serve*(d: Daemon) =
  d.bus = getBus(DBUS_BUS_SESSION)
  d.claimNameOrDie(BusName)
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

proc sendIntrospect*(): string =
  ## Client side: ask the daemon for its introspection XML through the
  ## same lib our daemon listens on. If this works while `busctl
  ## introspect` times out, the issue is busctl-side, not ours.
  let bus = getBus(DBUS_BUS_SESSION)
  var msg = makeCall(BusName, ObjPath.ObjectPath,
                     "org.freedesktop.DBus.Introspectable", "Introspect")
  let pending = bus.sendMessageWithReply(msg)
  let reply = pending.waitForReply()
  defer: reply.close()
  reply.raiseIfError()
  var iter = reply.iterate()
  result = iter.unpackCurrent(string)

proc sendWindowActivated*(exe, title, cls: string, pid: uint32) =
  ## Client side: synthesize a WindowActivated call. Useful for
  ## testing the matcher path without KWin.
  let bus = getBus(DBUS_BUS_SESSION)
  var msg = makeCall(BusName, ObjPath.ObjectPath, IfaceName, "WindowActivated")
  msg.append(exe)
  msg.append(title)
  msg.append(cls)
  msg.append(pid)
  let pending = bus.sendMessageWithReply(msg)
  let reply = pending.waitForReply()
  defer: reply.close()
  reply.raiseIfError()
