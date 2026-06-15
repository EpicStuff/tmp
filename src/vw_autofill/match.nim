## Match a focused window against a set of rules.
##
## Inputs are observable facts about the active window; outputs are
## the rules that would fire. The caller decides whether to act
## (auto-fire vs hotkey-only) and which one to pick when several
## match.

import std/[options, strutils, re]
import ./rule

type
  WindowInfo* = object
    exePath*: string  ## absolute path of the process exe
    exeName*: string  ## basename of exePath, lower-case-compared
    title*: string
    class*: string    ## resourceClass / WM_CLASS / window class
    text*: string     ## focused-element text or accessible tree text

proc exeMatches(rule: Rule, w: WindowInfo): bool =
  if rule.exe.len == 0:
    return rule.unsafe   ## empty-exe rule needs unsafe to ever match
  if rule.exeIsFullPath:
    cmpIgnoreCase(rule.exe, w.exePath) == 0
  else:
    cmpIgnoreCase(rule.exe, w.exeName) == 0

proc titleMatches(rule: Rule, w: WindowInfo): bool =
  if rule.title.len > 0 and rule.title notin w.title:
    return false
  if rule.titleRegex.len > 0:
    try:
      if not w.title.contains(re(rule.titleRegex)):
        return false
    except RegexError:
      return false
  true

proc classMatches(rule: Rule, w: WindowInfo): bool =
  rule.class.len == 0 or rule.class == w.class

proc textMatches(rule: Rule, w: WindowInfo): bool =
  rule.text.len == 0 or rule.text in w.text

proc matches*(rule: Rule, w: WindowInfo, platformIsLinux: bool): bool =
  if not rule.applies(platformIsLinux):
    return false
  if not rule.isSafe:
    return false
  if not rule.exeMatches(w):
    return false
  if not rule.titleMatches(w):
    return false
  if not rule.classMatches(w):
    return false
  if not rule.textMatches(w):
    return false
  true

proc bestMatch*(rules: openArray[BoundRule], w: WindowInfo,
                platformIsLinux: bool): Option[BoundRule] =
  ## First rule whose `Rule` matches the window wins. Rule order in
  ## the input is the priority order; vault rule order is preserved
  ## from the `bw list items` output, so users can promote a rule by
  ## reordering its URI within the vault item's login.uris list.
  for br in rules:
    if br.rule.matches(w, platformIsLinux):
      return some(br)
  none(BoundRule)
