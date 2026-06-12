## vw-autofill — entry point.
##
## Subcommands today:
##   list     dump every matchable rule the vault exposes
##   status   report bw vault status
##
## More to come (daemon, fill, capture, unlock).

import std/[os, json]
import vw_autofill/[vault, rule]

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

proc usage() =
  echo """vw-autofill — Bitwarden/Vaultwarden desktop autofill

Usage:
    vw-autofill <command>

Commands:
    list      list every rule URI in your unlocked vault
    status    print bw vault status JSON
    help      this message

Requires BW_SESSION in the environment (obtain via `bw unlock --raw`).
"""

when isMainModule:
  if paramCount() == 0:
    usage()
    quit 1
  case paramStr(1)
  of "list": cmdList()
  of "status": cmdStatus()
  of "help", "--help", "-h": usage()
  else:
    stderr.writeLine "unknown command: " & paramStr(1)
    usage()
    quit 1
