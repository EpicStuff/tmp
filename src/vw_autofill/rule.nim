## Rule data model. A Rule is one parsed URI from a vault item's
## .login.uris list, plus the vault credentials that the URI belongs to.

type
  Scheme* = enum
    skWinapp = "winapp"
    skLinapp = "linapp"
    skApp = "app"

  Mode* = enum
    mHotkey = "hotkey"
    mAuto = "auto"

  Rule* = object
    scheme*: Scheme
    exe*: string
    exeIsFullPath*: bool
    title*: string
    titleRegex*: string
    class*: string
    text*: string
    mode*: Mode
    sequence*: string
    cooldown*: int
    fieldCheck*: bool
    unsafe*: bool

  Credential* = object
    itemId*: string
    itemName*: string
    username*: string
    password*: string
    totpSecret*: string

  BoundRule* = object
    rule*: Rule
    credential*: Credential

const DefaultSequence* = "$user$tab$pass$enter"
const DefaultCooldownSeconds* = 15

proc applies*(rule: Rule, platformIsLinux: bool): bool =
  case rule.scheme
  of skWinapp: not platformIsLinux
  of skLinapp: platformIsLinux
  of skApp: true

proc hasMatcher*(rule: Rule): bool =
  rule.title.len > 0 or rule.titleRegex.len > 0 or
    rule.class.len > 0 or rule.text.len > 0

proc isSafe*(rule: Rule): bool =
  ## A rule must either name an exe AND carry one other matcher,
  ## or have unsafe=1 set explicitly. Pure exe matching is allowed
  ## but only when unsafe is opted in.
  if rule.unsafe:
    return true
  if rule.exe.len == 0:
    return false
  if rule.mode == mAuto:
    return rule.hasMatcher
  true
