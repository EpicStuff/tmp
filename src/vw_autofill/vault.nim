## Vault backend abstraction.
##
## Concrete impls so far: BwBackend (official `bw` CLI). The interface
## is a closure-based VTable so we can swap in `rbw` on Linux later
## without touching call sites.

import std/[json, options, osproc, os, strtabs, streams]
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

proc runBw(args: openArray[string], session: string): tuple[output: string, code: int] =
  ## Run bw with BW_SESSION + BW_NOINTERACTION set. Capture stdout.
  var env = newStringTable()
  for k, v in envPairs():
    env[k] = v
  env["BW_SESSION"] = session
  env["BW_NOINTERACTION"] = "true"
  let p = startProcess(
    "bw",
    args = @args,
    options = {poUsePath, poStdErrToStdOut},
    env = env,
  )
  defer: p.close()
  let output = p.outputStream.readAll()
  let code = p.waitForExit()
  (output, code)

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
    let (output, code) = runBw(["list", "items"], sessionCopy)
    if code != 0:
      raise newException(VaultError, "bw list items failed: " & output)
    let root = parseJson(output)
    for item in root:
      if item{"type"}.getInt != 1:  ## type 1 = login
        continue
      result.add credentialOf(item)

  result.statusImpl = proc(): JsonNode =
    let (output, code) = runBw(["status"], sessionCopy)
    if code != 0:
      raise newException(VaultError, "bw status failed: " & output)
    parseJson(output)

proc collectRules*(b: VaultBackend): seq[BoundRule] =
  ## Convenience: pull items via bw and re-fetch URIs from the raw JSON.
  ## (We re-shell because the credential carrier above doesn't yet
  ## hold URIs; that's a deliberate split — URIs are rule data,
  ## credentials are secret data.)
  let s = b.statusImpl()
  if s{"status"}.getStr != "unlocked":
    raise newException(VaultError, "vault is " & s{"status"}.getStr)

  let session = getEnv("BW_SESSION")
  let (output, code) = runBw(["list", "items"], session)
  if code != 0:
    raise newException(VaultError, "bw list items failed: " & output)
  let root = parseJson(output)
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
