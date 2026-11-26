"""Run inside a test D-Bus session with a PipeWire test camera and the probe executable."""
import os
import socket
import subprocess
import sys
from gi.repository import Gio, GLib

bus = Gio.bus_get_sync(Gio.BusType.SESSION, None)
interface = Gio.DBusNodeInfo.new_for_xml("""
<node><interface name="org.freedesktop.portal.Camera">
<method name="AccessCamera"><arg type="a{sv}" direction="in"/><arg type="o" direction="out"/></method>
<method name="OpenPipeWireRemote"><arg type="a{sv}" direction="in"/><arg type="h" direction="out"/></method>
<property name="version" type="u" access="read"/><property name="IsCameraPresent" type="b" access="read"/>
</interface></node>""").interfaces[0]
granted = set()
requests = []


def method(connection, sender, path, iface, member, params, reply):
    if member == "AccessCamera":
        token = params.unpack()[0]["handle_token"]
        request = "/org/freedesktop/portal/desktop/request/" + sender[1:].replace(".", "_") + "/" + token
        requests.append(sender)
        status = 1 if len(requests) == 1 else 0
        if status == 0:
            granted.add(sender)
        reply.return_value(GLib.Variant("(o)", (request,)))

        def respond():
            connection.emit_signal(sender, request, "org.freedesktop.portal.Request", "Response",
                                   GLib.Variant("(ua{sv})", (status, {})))
            return False
        GLib.idle_add(respond)
    elif member == "OpenPipeWireRemote" and sender in granted:
        with socket.socket(socket.AF_UNIX, socket.SOCK_STREAM) as remote:
            remote.connect(os.path.join(os.environ["XDG_RUNTIME_DIR"], "pipewire-0"))
            fds = Gio.UnixFDList.new()
            index = fds.append(remote.fileno())
            reply.return_value_with_unix_fd_list(GLib.Variant("(h)", (index,)), fds)
    else:
        reply.return_dbus_error("org.freedesktop.portal.Error.NotAllowed", "Camera access requires consent")


def prop(connection, sender, path, iface, name):
    return GLib.Variant("u", 1) if name == "version" else GLib.Variant("b", True)


bus.register_object("/org/freedesktop/portal/desktop", interface, method, prop, None)
bus.call_sync("org.freedesktop.DBus", "/org/freedesktop/DBus", "org.freedesktop.DBus", "RequestName",
              GLib.Variant("(su)", ("org.freedesktop.portal.Desktop", 0)), None, 0, 5000, None)
client = subprocess.Popen(sys.argv[1:])
loop = GLib.MainLoop()


def poll():
    if client.poll() is None:
        return True
    loop.quit()
    return False


GLib.timeout_add(30, poll)
GLib.timeout_add_seconds(25, lambda: (client.kill(), False)[1] if client.poll() is None else False)
loop.run()
if client.returncode != 0:
    raise SystemExit(client.returncode)
assert len(requests) == 2
