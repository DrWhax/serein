"""Run under dbus-run-session, passing the path to a built DesktopBus shared library."""
import ctypes
import subprocess
import sys

from gi.repository import Gio, GLib

if len(sys.argv) == 3 and sys.argv[2] == "client":
    bridge = ctypes.CDLL(sys.argv[1])
    bridge.serein_display_inhibit.restype = ctypes.c_uint64
    bridge.serein_display_uninhibit.argtypes = [ctypes.c_uint64]
    first = bridge.serein_display_inhibit()
    second = bridge.serein_display_inhibit()
    assert first and second and first != second
    bridge.serein_display_uninhibit(second)
    bridge.serein_display_uninhibit(first)
    sys.exit(0)

name = "org.freedesktop.ScreenSaver"
bus = Gio.bus_get_sync(Gio.BusType.SESSION, None)
interface = Gio.DBusNodeInfo.new_for_xml(
    '<node><interface name="org.freedesktop.ScreenSaver">'
    '<method name="Inhibit"><arg type="s" direction="in"/><arg type="s" direction="in"/>'
    '<arg type="u" direction="out"/></method>'
    '<method name="UnInhibit"><arg type="u" direction="in"/></method></interface></node>'
).interfaces[0]
leases = {}
released = []


def method(connection, sender, path, iface, member, params, reply):
    if member == "Inhibit" and params.unpack() == ("Serein", "Signal call in progress"):
        cookie = len(leases)
        leases[cookie] = sender
        reply.return_value(GLib.Variant("(u)", (cookie,)))
    elif member == "UnInhibit" and leases.get(params[0]) == sender:
        released.append(params[0])
        del leases[params[0]]
        reply.return_value(None)
    else:
        reply.return_dbus_error("org.freedesktop.DBus.Error.Failed", "invalid lease")


bus.register_object("/org/freedesktop/ScreenSaver", interface, method, None, None)
bus.call_sync("org.freedesktop.DBus", "/org/freedesktop/DBus", "org.freedesktop.DBus",
              "RequestName", GLib.Variant("(su)", (name, 0)), None, 0, 5000, None)
client = subprocess.Popen([sys.executable, __file__, sys.argv[1], "client"])
loop = GLib.MainLoop()


def finished():
    if client.poll() is None:
        return True
    loop.quit()
    return False


GLib.timeout_add(10, finished)
loop.run()
assert client.returncode == 0 and not leases and released == [1, 0]
print("PASS: two independent idle inhibitors, including cookie zero, released on the original session bus connection")
