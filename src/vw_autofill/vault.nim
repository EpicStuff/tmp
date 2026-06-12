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
    listLoginsImpl*: proc(): seq[Credential] {.closure.}
    statusImpl*: proc(): JsonNode {.closure.}

proc listLogins*(b: VaultBackend): seq[Credential] =
  b.listLoginsImpl()

proc status*(b: VaultBackend): JsonNode =
  b.statusImpl()

proc runBw(args: openArray[string], session: string): tuple[output, errOutput: string, code: int] =
  ## Run bw with BW_SESSION + BW_NOINTERACTION set. Capture stdout and
  ## stderr *separately* — bw prints non-JSON noise (deprecation
  ## warnings, network errors, login banners) to stderr; merging it
  ## into stdout corrupts the JSON parse downstream.
  var env = newStringTable()
  for k, v in envPairs():
    env[k] = v
  env["BW_SESSION"] = session
  env["BW_NOINTERACTION"] = "true"
  let p = startProcess(
    "bw",
    args = @args,
    options = {poUsePath},
    env = env,
  )
  defer: p.close()
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

  result = VaultBackend()
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

proc collectRules*(b: VaultBackend): seq[BoundRule] =
  ## Convenience: pull items via bw and re-fetch URIs from the raw JSON.
  ## (We re-shell because the credential carrier above doesn't yet
  ## hold URIs; that's a deliberate split — URIs are rule data,
  ## credentials are secret data.)
  let s = b.statusImpl()
  if s{"status"}.getStr != "unlocked":
    raise newException(VaultError, "vault is " & s{"status"}.getStr)

  let session = getEnv("BW_SESSION")
  let (output, errOutput, code) = runBw(["list", "items"], session)
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
