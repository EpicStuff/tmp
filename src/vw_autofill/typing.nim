## ydotool wrapper. Talks to a running ydotoold via YDOTOOL_SOCKET.
##
## We shell out instead of linking libydotool because ydotool ships
## a stable CLI and no public C API; the shell-out cost is negligible
## next to the human-scale typing delay it introduces anyway.

import std/[os, osproc, strtabs, streams, strutils]
import ./rule

## Default ydotoold socket path the daemon expects. Matches what the
## systemd unit lays down with --socket-perm=0666.
const DefaultYdotoolSocket* = "/tmp/.ydotool_socket"

type
  TypingError* = object of CatchableError

proc runYdotool(args: openArray[string], socket: string): tuple[output: string, code: int] =
  var env = newStringTable()
  for k, v in envPairs():
    env[k] = v
  env["YDOTOOL_SOCKET"] = socket
  let p = startProcess(
    "ydotool",
    args = @args,
    options = {poUsePath, poStdErrToStdOut},
    env = env,
  )
  defer: p.close()
  let output = p.outputStream.readAll()
  let code = p.waitForExit()
  (output, code)

proc typeText*(text: string, socket = DefaultYdotoolSocket) =
  if text.len == 0: return
  let (output, code) = runYdotool(["type", "--", text], socket)
  if code != 0:
    raise newException(TypingError, "ydotool type failed: " & output)

proc pressKey*(keycode: string, socket = DefaultYdotoolSocket) =
  ## keycode is ydotool's "KEY:1 KEY:0" syntax (press, release).
  ## Examples: "15:1 15:0" = Tab; "28:1 28:0" = Enter.
  let (output, code) = runYdotool(["key", "--", keycode], socket)
  if code != 0:
    raise newException(TypingError, "ydotool key failed: " & output)

const
  TabKeycode*   = "15:1 15:0"
  EnterKeycode* = "28:1 28:0"

proc pressTab*(socket = DefaultYdotoolSocket) = pressKey(TabKeycode, socket)
proc pressEnter*(socket = DefaultYdotoolSocket) = pressKey(EnterKeycode, socket)

proc playSequence*(s: string, cred: Credential, socket = DefaultYdotoolSocket) =
  ## Expand $user / $pass / $totp / $tab / $enter tokens and drive
  ## the typing layer. Literal text between tokens is typed verbatim.
  ## $totp expands to the *secret* string today; TOTP code generation
  ## comes later (will need an OTP helper).
  var i = 0
  var buf = ""
  template flushBuf() =
    if buf.len > 0:
      typeText(buf, socket)
      buf = ""
  while i < s.len:
    if s[i] == '$':
      let rest = s[i+1 .. ^1]
      if rest.startsWith("user"):
        flushBuf(); typeText(cred.username, socket); i += 5
      elif rest.startsWith("pass"):
        flushBuf(); typeText(cred.password, socket); i += 5
      elif rest.startsWith("totp"):
        flushBuf(); typeText(cred.totpSecret, socket); i += 5
      elif rest.startsWith("tab"):
        flushBuf(); pressTab(socket); i += 4
      elif rest.startsWith("enter"):
        flushBuf(); pressEnter(socket); i += 6
      else:
        buf.add s[i]; inc i
    else:
      buf.add s[i]; inc i
  flushBuf()
