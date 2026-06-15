version       = "0.0.2"
author        = "vw-autofill"
description   = "Cross-platform desktop autofill for Bitwarden/Vaultwarden"
license       = "MIT"

srcDir        = "src"
binDir        = "bin"
bin           = @["vw_autofill"]

requires "nim >= 2.0.0"
requires "dbus"

task test, "Run unit tests":
  exec "nim r -d:release tests/test_uri.nim"
  exec "nim r -d:release tests/test_match.nim"

task integration, "Run integration tests (requires live test Vaultwarden + bw)":
  exec "python3 tests/integration.py"
