version       = "0.0.1"
author        = "vw-autofill"
description   = "Cross-platform desktop autofill for Bitwarden/Vaultwarden"
license       = "MIT"

srcDir        = "src"
binDir        = "bin"
bin           = @["vw_autofill"]

requires "nim >= 2.0.0"

task test, "Run tests":
  exec "nim r -d:release tests/test_uri.nim"
  exec "nim r -d:release tests/test_match.nim"
