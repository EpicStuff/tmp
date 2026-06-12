// vw-autofill KWin watcher.
//
// Hooks workspace.windowActivated and pushes (exe, title, class, pid)
// into the org.vwautofill.Daemon process over the session D-Bus bus.
// Also registers a global keybind that fires Fill() on the daemon.
//
// Plasma 6 doesn't reliably route script print() to the user journal,
// so diagnostic messages go through the daemon's Log() method instead.
// Anything we want to know shows up in the daemon log under a
// "[kwin-script]" prefix.

var BUS_SERVICE = "org.vwautofill.Daemon";
var BUS_PATH    = "/org/vwautofill/Daemon";
var BUS_IFACE   = "org.vwautofill.Daemon1";

function daemonLog(msg) {
    callDBus(BUS_SERVICE, BUS_PATH, BUS_IFACE, "Log", msg);
}

function pushActivation(window) {
    if (!window) return;
    var exe   = (window.resourceName  || "").toString();
    var title = (window.caption       || "").toString();
    var cls   = (window.resourceClass || "").toString();
    var pid   = (window.pid           || 0)  >>> 0;
    callDBus(BUS_SERVICE, BUS_PATH, BUS_IFACE,
             "WindowActivated", exe, title, cls, pid);
}

workspace.windowActivated.connect(pushActivation);
daemonLog("script v3 loaded; attempting registerShortcut(Meta+Alt+V)");

try {
    var ok = registerShortcut(
        "vw-autofill-fill",
        "vw-autofill: fill credentials into focused window",
        "Meta+Alt+V",
        function() {
            daemonLog("shortcut Meta+Alt+V fired");
            callDBus(BUS_SERVICE, BUS_PATH, BUS_IFACE, "Fill");
        }
    );
    daemonLog("registerShortcut returned: " + ok);
} catch (e) {
    daemonLog("registerShortcut threw: " + e);
}
