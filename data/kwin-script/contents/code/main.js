// vw-autofill KWin watcher.
//
// Hooks workspace.windowActivated and pushes (exe, title, class, pid)
// into the org.vwautofill.Daemon process over the session D-Bus bus.
//
// KWin's callDBus signature:
//   callDBus(service, path, iface, method, ...args)
// We pass strings for exe/title/class. KWin doesn't expose the process
// exe path on Wayland, so we send the resourceName (== exe basename for
// most apps) as the exe slot; the daemon will compare against it.

function pushActivation(window) {
    if (!window) return;
    var exe   = (window.resourceName  || "").toString();
    var title = (window.caption       || "").toString();
    var cls   = (window.resourceClass || "").toString();
    var pid   = (window.pid           || 0)  >>> 0;
    callDBus(
        "org.vwautofill.Daemon",
        "/org/vwautofill/Daemon",
        "org.vwautofill.Daemon1",
        "WindowActivated",
        exe, title, cls, pid
    );
}

workspace.windowActivated.connect(pushActivation);
