## Session-bus daemon. Owns org.vwautofill.Daemon at path
## /org/vwautofill/Daemon.
##
## Method set lives in two places: the introspection XML below (what
## clients see) and the `dispatch` case (what we actually serve). Keep
## them in sync — adding a method needs both an XML entry and a case
## arm.

import std/[os, options, json]
import dbus
import dbus/lowlevel
import ./[rule, match, typing, vault]

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
    </method>
    <method name="Fill"/>
    <method name="LastWindow">
      <arg type="s" name="exe"   direction="out"/>
      <arg type="s" name="title" direction="out"/>
      <arg type="s" name="class" direction="out"/>
    </method>
    <method name="Reload">
      <arg type="u" name="rule_count" direction="out"/>
    </method>
    <method name="ListItems">
      <arg type="as" name="ids"   direction="out"/>
      <arg type="as" name="names" direction="out"/>
    </method>
    <method name="AddUriToItem">
      <arg type="s" name="item_id" direction="in"/>
      <arg type="s" name="uri"     direction="in"/>
    </method>
    <method name="ListRules">
      <arg type="as" name="lines" direction="out"/>
    </method>
    <method name="Status">
      <arg type="s" name="json" direction="out"/>
    </method>
    <method name="UnlockWith">
      <arg type="s" name="session" direction="in"/>
      <arg type="u" name="rule_count" direction="out"/>
    </method>
    <method name="Log">
      <arg type="s" name="message" direction="in"/>
    </method>
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
    backend*: BwBackend
      ## nil = locked. Methods that need the vault error out until
      ## UnlockWith populates this.
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
  d.lastMatch = bestMatch(d.rules, d.lastWindow, platformIsLinux = true)

proc handleWindowActivated(d: Daemon, args: seq[DbusValue]): bool =
  if args.len < 3:
    d.log "WindowActivated: bad arg count " & $args.len
    return false
  let exe   = args[0].asNative(string)
  let title = args[1].asNative(string)
  let cls   = args[2].asNative(string)
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
  d.log "activated exe=" & exe & " class=" & cls &
    " title=" & title & " -> " & label
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

proc handleLastWindow(d: Daemon, bus: Bus, incoming: IncomingMessage): bool =
  bus.sendReply(incoming, @[
    asDbusValue(d.lastWindow.exePath),
    asDbusValue(d.lastWindow.title),
    asDbusValue(d.lastWindow.class),
  ])
  true

proc requireUnlocked(d: Daemon, bus: Bus, incoming: IncomingMessage, name: string): bool =
  ## Returns true if backend is present. On a locked vault, sends an
  ## error reply and returns false; caller should bail.
  if d.backend != nil: return true
  bus.sendErrorReply(incoming, name & ": vault is locked")
  false

proc handleReload(d: Daemon, bus: Bus, incoming: IncomingMessage): bool =
  if not d.requireUnlocked(bus, incoming, "Reload"): return true
  try:
    d.rules = d.backend.collectRules()
    d.recomputeMatch()
    d.log "reloaded: " & $d.rules.len & " rule(s)"
    bus.sendReply(incoming, @[asDbusValue(d.rules.len.uint32)])
  except CatchableError as e:
    bus.sendErrorReply(incoming, "Reload failed: " & e.msg)
  true

proc handleListItems(d: Daemon, bus: Bus, incoming: IncomingMessage): bool =
  if not d.requireUnlocked(bus, incoming, "ListItems"): return true
  try:
    let creds = d.backend.listLogins()
    var ids: seq[string]
    var names: seq[string]
    for c in creds:
      ids.add c.itemId
      names.add c.itemName
    bus.sendReply(incoming, @[asDbusValue(ids), asDbusValue(names)])
  except CatchableError as e:
    bus.sendErrorReply(incoming, "ListItems failed: " & e.msg)
  true

proc handleListRules(d: Daemon, bus: Bus, incoming: IncomingMessage): bool =
  ## Render each bound rule as a single human-readable line; clients
  ## just print. Keeps display formatting on the daemon so we don't
  ## have to repeat it across multiple clients.
  var lines: seq[string]
  for br in d.rules:
    let r = br.rule
    let scheme = $r.scheme
    let exeRepr = if r.exe.len == 0: "<empty>" else: r.exe
    var line = scheme & "://" & exeRepr &
      "  item=" & br.credential.itemName &
      "  mode=" & $r.mode
    if r.title.len > 0:      line &= "  title=" & r.title
    if r.titleRegex.len > 0: line &= "  title_regex=" & r.titleRegex
    if r.class.len > 0:      line &= "  class=" & r.class
    if r.text.len > 0:       line &= "  text=" & r.text
    if r.unsafe:             line &= "  unsafe=1"
    lines.add line
  bus.sendReply(incoming, @[asDbusValue(lines)])
  true

proc handleStatus(d: Daemon, bus: Bus, incoming: IncomingMessage): bool =
  ## Returns a JSON string with daemon health + vault status + the
  ## last-seen window. Single string return keeps the wire signature
  ## stable as we add fields.
  var obj = newJObject()
  obj["pid"] = newJInt(getCurrentProcessId())
  obj["rules"] = newJInt(d.rules.len)
  if d.backend == nil:
    obj["vault"] = newJString("locked")
  else:
    try:
      obj["vault"] = d.backend.status()
    except CatchableError as e:
      obj["vault_error"] = newJString(e.msg)
  var lw = newJObject()
  lw["exe"] = newJString(d.lastWindow.exePath)
  lw["title"] = newJString(d.lastWindow.title)
  lw["class"] = newJString(d.lastWindow.class)
  obj["last_window"] = lw
  if d.lastMatch.isSome:
    obj["last_match"] = newJString(d.lastMatch.get.credential.itemName)
  else:
    obj["last_match"] = newJNull()
  bus.sendReply(incoming, @[asDbusValue($obj)])
  true

proc handleAddUriToItem(d: Daemon, bus: Bus, incoming: IncomingMessage): bool =
  if not d.requireUnlocked(bus, incoming, "AddUriToItem"): return true
  let args = incoming.unpackValueSeq()
  if args.len < 2:
    bus.sendErrorReply(incoming, "AddUriToItem: bad arg count " & $args.len)
    return true
  try:
    let itemId = args[0].asNative(string)
    let uri    = args[1].asNative(string)
    d.backend.addUriToItem(itemId, uri)
    # Re-fetch so the new URI becomes a live rule immediately.
    d.rules = d.backend.collectRules()
    d.recomputeMatch()
    d.log "added URI to " & itemId & "; now " & $d.rules.len & " rule(s)"
    bus.sendReply(incoming, @[])
  except CatchableError as e:
    bus.sendErrorReply(incoming, "AddUriToItem failed: " & e.msg)
  true

proc handleUnlockWith(d: Daemon, bus: Bus, incoming: IncomingMessage): bool =
  ## Caller (typically `vw-autofill unlock` after `bw unlock --raw`)
  ## hands us a session token. We validate by loading rules.
  let args = incoming.unpackValueSeq()
  if args.len < 1:
    bus.sendErrorReply(incoming, "UnlockWith: bad arg count " & $args.len)
    return true
  let token = args[0].asNative(string)
  if token.len == 0:
    bus.sendErrorReply(incoming, "UnlockWith: empty token")
    return true
  try:
    let nb = newBwBackend(token)
    d.rules = nb.collectRules()
    d.backend = nb
    d.recomputeMatch()
    d.log "unlocked: " & $d.rules.len & " rule(s)"
    bus.sendReply(incoming, @[asDbusValue(d.rules.len.uint32)])
  except CatchableError as e:
    bus.sendErrorReply(incoming, "UnlockWith failed: " & e.msg)
  true

proc dispatch(d: Daemon, kind: IncomingMessageType, incoming: IncomingMessage): bool =
  # Every method name in this case must also appear in `introspectionXml` above.
  let iface = incoming.interfaceName
  let name  = incoming.name
  d.log "recv kind=" & $kind & " iface='" & iface & "' name='" & name & "'"
  if iface == IfaceName:
    case name
    of "WindowActivated":
      let args = incoming.unpackValueSeq()
      discard d.handleWindowActivated(args)
      d.bus.sendReply(incoming, @[])
      return true
    of "Fill":
      discard d.handleFill()
      d.bus.sendReply(incoming, @[])
      return true
    of "LastWindow":
      return d.handleLastWindow(d.bus, incoming)
    of "Reload":
      return d.handleReload(d.bus, incoming)
    of "ListItems":
      return d.handleListItems(d.bus, incoming)
    of "AddUriToItem":
      return d.handleAddUriToItem(d.bus, incoming)
    of "ListRules":
      return d.handleListRules(d.bus, incoming)
    of "Status":
      return d.handleStatus(d.bus, incoming)
    of "UnlockWith":
      return d.handleUnlockWith(d.bus, incoming)
    of "Log":
      let args = incoming.unpackValueSeq()
      if args.len >= 1:
        d.log "[kwin-script] " & args[0].asNative(string)
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

proc makeCallback(d: Daemon): MessageCallback =
  # We must NEVER let an exception (or worse, a defect) cross the cdecl
  # boundary back into libdbus -- it leaves the dispatcher in an
  # inconsistent state and the daemon stops processing messages
  # without dying, so clients hit NoReply forever. Catch everything
  # here, log it, and try to send some kind of reply.
  result = proc(kind: IncomingMessageType, incoming: IncomingMessage): bool =
    try:
      return d.dispatch(kind, incoming)
    except Exception as e:
      d.log "callback EXCEPTION: " & $e.name & ": " & e.msg
      try:
        d.bus.sendErrorReply(incoming, "vw-autofill: " & e.msg)
      except CatchableError:
        discard
      return true

proc newDaemon*(backend: BwBackend, rules: sink seq[BoundRule] = @[],
                socket = DefaultYdotoolSocket, logPath = ""): Daemon =
  ## `backend` may be nil — daemon starts locked, waits for
  ## UnlockWith. Caller passes the pre-validated rule set so we don't
  ## re-shell out to bw at startup.
  result = Daemon(
    backend: backend, rules: rules,
    socket: socket, lastMatch: none(BoundRule),
  )
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
  if d.backend == nil:
    d.log "locked — waiting for UnlockWith"
  else:
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

proc sendWindowActivated*(exe, title, cls: string) =
  ## Client side: synthesize a WindowActivated call. Useful for
  ## testing the matcher path without a live window monitor.
  let bus = getBus(DBUS_BUS_SESSION)
  var msg = makeCall(BusName, ObjPath.ObjectPath, IfaceName, "WindowActivated")
  msg.append(exe)
  msg.append(title)
  msg.append(cls)
  let pending = bus.sendMessageWithReply(msg)
  let reply = pending.waitForReply()
  defer: reply.close()
  reply.raiseIfError()

proc sendReload*(): uint32 =
  ## Client side: ask the running daemon to refetch rules from bw.
  ## Returns new rule count.
  let bus = getBus(DBUS_BUS_SESSION)
  var msg = makeCall(BusName, ObjPath.ObjectPath, IfaceName, "Reload")
  let pending = bus.sendMessageWithReply(msg)
  let reply = pending.waitForReply()
  defer: reply.close()
  reply.raiseIfError()
  var iter = reply.iterate()
  result = iter.unpackCurrent(uint32)

proc sendListItems*(): tuple[ids, names: seq[string]] =
  ## Ask the daemon for its current vault item list. Uses the
  ## daemon's session token — caller doesn't need BW_SESSION.
  let bus = getBus(DBUS_BUS_SESSION)
  var msg = makeCall(BusName, ObjPath.ObjectPath, IfaceName, "ListItems")
  let pending = bus.sendMessageWithReply(msg)
  let reply = pending.waitForReply()
  defer: reply.close()
  reply.raiseIfError()
  var iter = reply.iterate()
  result.ids = iter.unpackCurrent(seq[string])
  iter.advanceIter()
  result.names = iter.unpackCurrent(seq[string])

proc sendAddUriToItem*(itemId, uri: string) =
  ## Ask the daemon to append `uri` to `itemId`'s login.uris. Daemon
  ## does the bw round-trip + reloads its rule cache.
  let bus = getBus(DBUS_BUS_SESSION)
  var msg = makeCall(BusName, ObjPath.ObjectPath, IfaceName, "AddUriToItem")
  msg.append(itemId)
  msg.append(uri)
  let pending = bus.sendMessageWithReply(msg)
  let reply = pending.waitForReply()
  defer: reply.close()
  reply.raiseIfError()

proc sendListRules*(): seq[string] =
  let bus = getBus(DBUS_BUS_SESSION)
  var msg = makeCall(BusName, ObjPath.ObjectPath, IfaceName, "ListRules")
  let pending = bus.sendMessageWithReply(msg)
  let reply = pending.waitForReply()
  defer: reply.close()
  reply.raiseIfError()
  var iter = reply.iterate()
  result = iter.unpackCurrent(seq[string])

proc sendStatus*(): string =
  let bus = getBus(DBUS_BUS_SESSION)
  var msg = makeCall(BusName, ObjPath.ObjectPath, IfaceName, "Status")
  let pending = bus.sendMessageWithReply(msg)
  let reply = pending.waitForReply()
  defer: reply.close()
  reply.raiseIfError()
  var iter = reply.iterate()
  result = iter.unpackCurrent(string)

proc sendLastWindow*(): tuple[exe, title, cls: string] =
  ## Client side: ask the daemon what window it most recently saw
  ## activated. Used by the capture flow.
  let bus = getBus(DBUS_BUS_SESSION)
  var msg = makeCall(BusName, ObjPath.ObjectPath, IfaceName, "LastWindow")
  let pending = bus.sendMessageWithReply(msg)
  let reply = pending.waitForReply()
  defer: reply.close()
  reply.raiseIfError()
  var iter = reply.iterate()
  result.exe = iter.unpackCurrent(string)
  iter.advanceIter()
  result.title = iter.unpackCurrent(string)
  iter.advanceIter()
  result.cls = iter.unpackCurrent(string)

proc sendUnlockWith*(token: string): uint32 =
  ## Hand a fresh `bw unlock --raw` token to a running daemon.
  ## Returns the new rule count after the daemon validates and
  ## reloads against the token.
  let bus = getBus(DBUS_BUS_SESSION)
  var msg = makeCall(BusName, ObjPath.ObjectPath, IfaceName, "UnlockWith")
  msg.append(token)
  let pending = bus.sendMessageWithReply(msg)
  let reply = pending.waitForReply()
  defer: reply.close()
  reply.raiseIfError()
  var iter = reply.iterate()
  result = iter.unpackCurrent(uint32)
