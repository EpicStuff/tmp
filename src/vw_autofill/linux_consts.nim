## Linux platform constants. Hard-coded values that don't vary
## across our supported environments and don't need discovery at
## runtime.

## ydotoold creates a virtual uinput device with these IDs
## (compiled into the ydotool binary; see Daemon.cpp in upstream).
## Used to filter ydotool out of input-grabbing daemons like keyd.
const
  YdotoolVendor*  = 0x2333
  YdotoolProduct* = 0x6666

func ydotoolIdHex*(): string =
  ## "2333:6666" - the form used by keyd's [ids] section.
  "2333:6666"

## Default ydotoold socket path the daemon expects (matches
## what the runtime systemd unit lays down with --socket-perm=0666).
const DefaultYdotoolSocket* = "/tmp/.ydotool_socket"
