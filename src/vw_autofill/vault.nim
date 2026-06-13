## Vault backend abstraction.
##
## Concrete impls so far: BwBackend (official `bw` CLI). The interface
## is a closure-based VTable so we can swap in `rbw` on Linux later
## without touching call sites.

import std/[json, options, osproc, os, strtabs, streams, strutils]
import ./rule
import ./uri

type
  VaultError* = object of CatchableError

  VaultBackend* = ref object
    session*: string
    listLoginsImpl*: proc(): seq[Credential] {.closure.}
    statusImpl*: proc(): JsonNode {.closure.}

proc listLogins*(b: VaultBackend): seq[Credential] =
  b.listLoginsImpl()

proc status*(b: VaultBackend): JsonNode =
  b.statusImpl()

proc bwEnv(session: string): StringTableRef =
  result = newStringTable()
  for k, v in envPairs():
    result[k] = v
  result["BW_SESSION"] = session
  result["BW_NOINTERACTION"] = "true"

proc runBw(args: openArray[string], session: string): tuple[output, errOutput: string, code: int] =
  ## Run bw with BW_SESSION + BW_NOINTERACTION set. Capture stdout and
  ## stderr *separately* — bw prints non-JSON noise (deprecation
  ## warnings, network errors, login banners) to stderr; merging it
  ## into stdout corrupts the JSON parse downstream.
  let p = startProcess(
    "bw",
    args = @args,
    options = {poUsePath},
    env = bwEnv(session),
  )
  defer: p.close()
  let output = p.outputStream.readAll()
  let errOutput = p.errorStream.readAll()
  let code = p.waitForExit()
  (output, errOutput, code)

proc runBwStdin(args: openArray[string], session, stdinInput: string): tuple[output, errOutput: string, code: int] =
  ## Like runBw but pipes `stdinInput` into bw's stdin. Used for
  ## `bw encode` and `bw edit item <id>` which take JSON on stdin.
  let p = startProcess(
    "bw",
    args = @args,
    options = {poUsePath},
    env = bwEnv(session),
  )
  defer: p.close()
  p.inputStream.write(stdinInput)
  p.inputStream.close()
  let output = p.outputStream.readAll()
  let errOutput = p.errorStream.readAll()
  let code = p.waitForExit()
  (output, errOutput, code)

proc parseBwJson(output, errOutput: string, code: int, ctx: string): JsonNode =
  ## Common error-surfacing wrapper. On any failure include both code
  ## and the first 400 chars of each stream so we can see what bw said.
  proc snippet(s: string): string =
    let s2 = s.strip()
    if s2.len <= 400: s2 else: s2[0 ..< 400] & "...(truncated)"
  if code != 0:
    raise newException(VaultError,
      ctx & " exit=" & $code &
      "; stderr=" & snippet(errOutput) &
      "; stdout=" & snippet(output))
  try:
    return parseJson(output)
  except JsonParsingError as e:
    raise newException(VaultError,
      ctx & ": stdout was not JSON (" & e.msg & ")" &
      "; stderr=" & snippet(errOutput) &
      "; stdout=" & snippet(output))

proc credentialOf(item: JsonNode): Credential =
  Credential(
    itemId: item{"id"}.getStr,
    itemName: item{"name"}.getStr,
    username: item{"login", "username"}.getStr,
    password: item{"login", "password"}.getStr,
    totpSecret: item{"login", "totp"}.getStr,
  )

proc newBwBackend*(session: string): VaultBackend =
  if session.len == 0:
    raise newException(VaultError, "BW_SESSION is empty")

  result = VaultBackend(session: session)
  let sessionCopy = session

  result.listLoginsImpl = proc(): seq[Credential] =
    let (output, errOutput, code) = runBw(["list", "items"], sessionCopy)
    let root = parseBwJson(output, errOutput, code, "bw list items")
    for item in root:
      if item{"type"}.getInt != 1:  ## type 1 = login
        continue
      result.add credentialOf(item)

  result.statusImpl = proc(): JsonNode =
    let (output, errOutput, code) = runBw(["status"], sessionCopy)
    parseBwJson(output, errOutput, code, "bw status")

proc bwAddUriToItem*(itemId, newUri, session: string) =
  ## Fetch item, append `newUri` to its login.uris, push back via
  ## bw encode | bw edit item <id>. After this returns, bw's local
  ## cache holds the new URI and the daemon's next collectRules()
  ## will see it.
  let (gout, gerr, gcode) = runBw(@["get", "item", itemId], session)
  let item = parseBwJson(gout, gerr, gcode, "bw get item " & itemId)
  if item{"type"}.getInt != 1:
    raise newException(VaultError, "item " & itemId & " is not a login")
  if item{"login"}.isNil:
    item["login"] = newJObject()
  if item{"login", "uris"}.isNil:
    item["login"]["uris"] = newJArray()
  var entry = newJObject()
  entry["match"] = newJNull()
  entry["uri"] = newJString(newUri)
  item["login"]["uris"].add(entry)

  let (eout, eerr, ecode) = runBwStdin(@["encode"], session, $item)
  if ecode != 0:
    raise newException(VaultError, "bw encode failed: " & eerr & " stdout=" & eout)
  let encoded = eout.strip()

  let (uout, uerr, ucode) = runBwStdin(@["edit", "item", itemId], session, encoded)
  if ucode != 0:
    raise newException(VaultError, "bw edit item failed: " & uerr & " stdout=" & uout)

proc collectRules*(b: VaultBackend): seq[BoundRule] =
  ## Convenience: pull items via bw and re-fetch URIs from the raw JSON.
  ## (We re-shell because the credential carrier above doesn't yet
  ## hold URIs; that's a deliberate split — URIs are rule data,
  ## credentials are secret data.)
  ##
  ## Uses `b.session` (the token the backend was constructed with), not
  ## getEnv("BW_SESSION"). The daemon now passes session tokens around
  ## explicitly (cached file, fresh unlock) and never re-exports them
  ## into its own env, so re-reading env here was always empty —
  ## producing a "Vault is locked" from bw with no session.
  let s = b.statusImpl()
  if s{"status"}.getStr != "unlocked":
    raise newException(VaultError, "vault is " & s{"status"}.getStr)

  let (output, errOutput, code) = runBw(["list", "items"], b.session)
  let root = parseBwJson(output, errOutput, code, "bw list items")
  for item in root:
    if item{"type"}.getInt != 1:
      continue
    let cred = credentialOf(item)
    let uris = item{"login", "uris"}
    if uris.isNil:
      continue
    for u in uris:
      let raw = u{"uri"}.getStr
      let r = parseRuleUri(raw)
      if r.isSome:
        result.add BoundRule(rule: r.get, credential: cred)
