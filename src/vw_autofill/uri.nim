## URI parser for vw-autofill rule URIs.
##
## Grammar (extends the bitwarden-autotype `winapp://` convention):
##
##     <scheme>://<exe>?<k>=<v>&...
##
## Scheme is `winapp` (Windows), `linapp` (Linux), or `app` (either).
## Exe is a process name (`firefox`, `firefox.exe`) or, when prefixed
## with a slash (i.e. the URI starts with three slashes), a full path
## with standard percent-encoding.
##
## Query keys split into:
##   matchers: title, title_regex, class, text
##   behavior: mode, sequence, cooldown, field_check, unsafe

import std/[options, strutils, uri]
import ./rule

proc decodeIfNeeded(s: string): string =
  if '%' in s: decodeUrl(s, decodePlus = false) else: s

proc parseRuleUri*(s: string): Option[Rule] =
  let schemeEnd = s.find("://")
  if schemeEnd <= 0:
    return none(Rule)

  var scheme: Scheme
  case s[0 ..< schemeEnd]
  of "winapp": scheme = skWinapp
  of "linapp": scheme = skLinapp
  of "app": scheme = skApp
  else: return none(Rule)

  let rest = s[schemeEnd + 3 .. ^1]
  var exePart, queryPart: string
  let q = rest.find('?')
  if q >= 0:
    exePart = rest[0 ..< q]
    queryPart = rest[q + 1 .. ^1]
  else:
    exePart = rest

  var rule = Rule(
    scheme: scheme,
    mode: mHotkey,
    cooldown: DefaultCooldownSeconds,
  )

  if exePart.startsWith("/"):
    rule.exe = decodeIfNeeded(exePart)
    rule.exeIsFullPath = true
  else:
    rule.exe = decodeIfNeeded(exePart)

  if queryPart.len > 0:
    for pair in queryPart.split('&'):
      if pair.len == 0:
        continue
      let eq = pair.find('=')
      if eq < 0:
        continue
      let key = pair[0 ..< eq]
      let val = decodeIfNeeded(pair[eq + 1 .. ^1])
      case key
      of "title": rule.title = val
      of "title_regex": rule.titleRegex = val
      of "class": rule.class = val
      of "text": rule.text = val
      of "mode":
        case val
        of "auto": rule.mode = mAuto
        of "hotkey": rule.mode = mHotkey
        else: discard
      of "sequence", "seq": rule.sequence = val
      of "cooldown":
        try:
          rule.cooldown = parseInt(val)
        except ValueError:
          discard
      of "field_check": rule.fieldCheck = val in ["1", "true", "yes"]
      of "unsafe": rule.unsafe = val in ["1", "true", "yes"]
      else: discard

  if rule.sequence.len == 0:
    rule.sequence = DefaultSequence

  some(rule)
