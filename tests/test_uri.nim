import std/[unittest, options]
import ../src/vw_autofill/[uri, rule]

suite "parseRuleUri":

  test "basic linapp basename":
    let r = parseRuleUri("linapp://firefox?title=Login").get
    check r.scheme == skLinapp
    check r.exe == "firefox"
    check r.exeIsFullPath == false
    check r.title == "Login"
    check r.mode == mHotkey
    check r.sequence == DefaultSequence
    check r.cooldown == DefaultCooldownSeconds

  test "winapp with exe extension":
    let r = parseRuleUri("winapp://f5fpclientW.exe?mode=auto").get
    check r.scheme == skWinapp
    check r.exe == "f5fpclientW.exe"
    check r.mode == mAuto

  test "app cross-platform scheme":
    let r = parseRuleUri("app://something").get
    check r.scheme == skApp
    check r.applies(platformIsLinux = true)
    check r.applies(platformIsLinux = false)

  test "triple-slash full path":
    let r = parseRuleUri("linapp:///usr/bin/firefox?title=Login").get
    check r.exe == "/usr/bin/firefox"
    check r.exeIsFullPath == true

  test "windows full path with percent-encoded space":
    let r = parseRuleUri(
      "winapp:///C:/Program%20Files/Mozilla/firefox.exe?title=Sign%20in"
    ).get
    check r.exe == "/C:/Program Files/Mozilla/firefox.exe"
    check r.exeIsFullPath == true
    check r.title == "Sign in"

  test "all behavior knobs":
    let r = parseRuleUri(
      "linapp://x?mode=auto&sequence=$pass$enter&cooldown=30&field_check=1&unsafe=1"
    ).get
    check r.mode == mAuto
    check r.sequence == "$pass$enter"
    check r.cooldown == 30
    check r.fieldCheck == true
    check r.unsafe == true

  test "title_regex captured":
    let r = parseRuleUri("linapp://x?title_regex=^Sign.*in$").get
    check r.titleRegex == "^Sign.*in$"
    check r.title == ""

  test "class and text matchers":
    let r = parseRuleUri(
      "linapp://firefox?class=MozillaDialogClass&text=cotauth"
    ).get
    check r.class == "MozillaDialogClass"
    check r.text == "cotauth"

  test "unknown scheme is rejected":
    check parseRuleUri("https://example.com").isNone
    check parseRuleUri("plain text").isNone
    check parseRuleUri("").isNone

  test "empty exe with unsafe matcher":
    let r = parseRuleUri("linapp://?title=Banking&unsafe=1").get
    check r.exe == ""
    check r.title == "Banking"
    check r.unsafe == true

  test "invalid cooldown is silently ignored":
    let r = parseRuleUri("linapp://x?cooldown=hello").get
    check r.cooldown == DefaultCooldownSeconds

  test "unknown query keys are tolerated":
    let r = parseRuleUri("linapp://x?title=Foo&bogus=1&also_bogus=hi").get
    check r.title == "Foo"

  test "mode default is hotkey":
    let r = parseRuleUri("linapp://x").get
    check r.mode == mHotkey

  test "+ in query values decodes as space (form-encoded convention)":
    let r = parseRuleUri("linapp://openconnect?title=F5+VPN&mode=auto").get
    check r.title == "F5 VPN"

  test "%20 and + decode the same way":
    let a = parseRuleUri("linapp://x?title=Sign+in").get
    let b = parseRuleUri("linapp://x?title=Sign%20in").get
    check a.title == "Sign in"
    check b.title == "Sign in"
