import std/[unittest, options]
import ../src/vw_autofill/[uri, rule, match]

proc mk(s: string): Rule = parseRuleUri(s).get

const linux = true
const win = false

suite "rule matching":

  test "linapp basename matches process basename, case-insensitive":
    let rule = mk("linapp://firefox?title=Login")
    let w = WindowInfo(
      exePath: "/usr/bin/firefox",
      exeName: "Firefox",
      title: "Login - University of Toronto",
    )
    check rule.matches(w, linux)

  test "wrong exe name does not match":
    let rule = mk("linapp://firefox?title=Login")
    let w = WindowInfo(exeName: "chromium", title: "Login")
    check not rule.matches(w, linux)

  test "title substring is required when set":
    let rule = mk("linapp://firefox?title=Login")
    let w = WindowInfo(exeName: "firefox", title: "Welcome")
    check not rule.matches(w, linux)

  test "title_regex anchors work":
    let rule = mk("linapp://firefox?title_regex=^Sign in")
    let w1 = WindowInfo(exeName: "firefox", title: "Sign in to Acme")
    let w2 = WindowInfo(exeName: "firefox", title: "Please Sign in")
    check rule.matches(w1, linux)
    check not rule.matches(w2, linux)

  test "linapp does not match on Windows":
    let rule = mk("linapp://firefox")
    let w = WindowInfo(exeName: "firefox.exe")
    check not rule.matches(w, win)

  test "winapp does not match on Linux":
    let rule = mk("winapp://firefox.exe?unsafe=1")
    let w = WindowInfo(exeName: "firefox.exe")
    check not rule.matches(w, linux)

  test "app matches on both platforms":
    let rule = mk("app://firefox")
    let w = WindowInfo(exeName: "firefox")
    check rule.matches(w, linux)
    let w2 = WindowInfo(exeName: "firefox")
    check rule.matches(w2, win)

  test "class matcher must match exactly":
    let rule = mk("linapp://firefox?class=MozillaDialogClass")
    let wOk = WindowInfo(exeName: "firefox", class: "MozillaDialogClass")
    let wNo = WindowInfo(exeName: "firefox", class: "MozillaWindowClass")
    check rule.matches(wOk, linux)
    check not rule.matches(wNo, linux)

  test "text matcher is substring":
    let rule = mk("linapp://firefox?text=cotauth")
    let w = WindowInfo(exeName: "firefox", text: "Please sign in to cotauth.example")
    check rule.matches(w, linux)

  test "auto mode without secondary matcher is rejected":
    let rule = mk("linapp://firefox?mode=auto")
    let w = WindowInfo(exeName: "firefox")
    check not rule.matches(w, linux)

  test "auto mode with secondary matcher is allowed":
    let rule = mk("linapp://firefox?mode=auto&title=Login")
    let w = WindowInfo(exeName: "firefox", title: "Login")
    check rule.matches(w, linux)

  test "empty exe needs unsafe":
    let r1 = mk("linapp://?title=Banking")
    let r2 = mk("linapp://?title=Banking&unsafe=1")
    let w = WindowInfo(exeName: "firefox", title: "Banking")
    check not r1.matches(w, linux)
    check r2.matches(w, linux)

  test "full-path match against exePath, not exeName":
    let rule = mk("linapp:///usr/bin/firefox")
    let w = WindowInfo(exePath: "/usr/bin/firefox", exeName: "firefox")
    check rule.matches(w, linux)
    let w2 = WindowInfo(exePath: "/opt/firefox/firefox", exeName: "firefox")
    check not rule.matches(w2, linux)
