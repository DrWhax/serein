"""Run inside a test D-Bus session with a PipeWire test camera and the probe executable."""
import json
import os
from pathlib import Path
import runpy
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
selection_count = 0
sessions = {}
nodes = json.loads(subprocess.check_output(["pw-dump"]))
node_id = next(node["id"] for node in nodes if node.get("info", {}).get("props", {}).get("node.name") == "serein-test-camera")


def remote_fd(reply):
    with socket.socket(socket.AF_UNIX, socket.SOCK_STREAM) as remote:
        remote.connect(os.path.join(os.environ["XDG_RUNTIME_DIR"], "pipewire-0"))
        fds = Gio.UnixFDList.new()
        index = fds.append(remote.fileno())
        reply.return_value_with_unix_fd_list(GLib.Variant("(h)", (index,)), fds)


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
        remote_fd(reply)
    else:
        reply.return_dbus_error("org.freedesktop.portal.Error.NotAllowed", "Camera access requires consent")


def prop(connection, sender, path, iface, name):
    return GLib.Variant("u", 1) if name == "version" else GLib.Variant("b", True)


bus.register_object("/org/freedesktop/portal/desktop", interface, method, prop, None)
screencast = Gio.DBusNodeInfo.new_for_xml("""
<node><interface name="org.freedesktop.portal.ScreenCast">
<property name="version" type="u" access="read"/>
<property name="AvailableSourceTypes" type="u" access="read"/>
<property name="AvailableCursorModes" type="u" access="read"/>
<method name="CreateSession"><arg type="a{sv}" direction="in"/><arg type="o" direction="out"/></method>
<method name="SelectSources"><arg type="o" direction="in"/><arg type="a{sv}" direction="in"/><arg type="o" direction="out"/></method>
<method name="Start"><arg type="o" direction="in"/><arg type="s" direction="in"/><arg type="a{sv}" direction="in"/><arg type="o" direction="out"/></method>
<method name="OpenPipeWireRemote"><arg type="o" direction="in"/><arg type="a{sv}" direction="in"/><arg type="h" direction="out"/></method>
</interface></node>""").interfaces[0]
session_iface = Gio.DBusNodeInfo.new_for_xml("""
<node><interface name="org.freedesktop.portal.Session"><method name="Close"/>
<signal name="Closed"><arg type="a{sv}"/></signal></interface></node>""").interfaces[0]


def screen_property(connection, sender, path, iface, name):
    return GLib.Variant("u", 4 if name == "version" else 3)


def close_session(connection, sender, path, iface, member, params, reply):
    sessions.pop(path, None)
    reply.return_value(None)


def screen_method(connection, sender, path, iface, member, params, reply):
    global selection_count
    args = params.unpack()
    parent = "/org/freedesktop/portal/desktop/"
    owner = sender[1:].replace(".", "_")
    if member == "OpenPipeWireRemote":
        if sessions.get(args[0], {}).get("authorized") != sender:
            reply.return_dbus_error("org.freedesktop.portal.Error.NotAllowed", "No selected source")
            return
        remote_fd(reply)
        if selection_count == 2:
            def revoke():
                sessions.pop(args[0], None)
                connection.emit_signal(sender, args[0], "org.freedesktop.portal.Session", "Closed", GLib.Variant("(a{sv})", ({},)))
                return False
            GLib.timeout_add(1200, revoke)
        return

    options = args[-1]
    request = parent + "request/" + owner + "/" + options["handle_token"]
    response, results = 0, {}
    if member == "CreateSession":
        path = parent + "session/" + owner + "/" + options["session_handle_token"]
        sessions[path] = {"owner": sender}
        bus.register_object(path, session_iface, close_session, None, None)
        results = {"session_handle": GLib.Variant("s", path)}
    elif member == "SelectSources":
        assert sessions[args[0]]["owner"] == sender and options["types"] == 3
        assert not options.get("multiple", False)
    elif member == "Start":
        selection_count += 1
        if selection_count == 1:
            response = 1
        else:
            sessions[args[0]]["authorized"] = sender
            results = {"streams": GLib.Variant("a(ua{sv})", [(node_id, {"source_type": GLib.Variant("u", 2)})])}
    reply.return_value(GLib.Variant("(o)", (request,)))

    def respond():
        connection.emit_signal(sender, request, "org.freedesktop.portal.Request", "Response",
                               GLib.Variant("(ua{sv})", (response, results)))
        return False
    GLib.idle_add(respond)


bus.register_object("/org/freedesktop/portal/desktop", screencast, screen_method, screen_property, None)
# libportal checks both portal versions before creating a ScreenCast session.
remote_desktop = Gio.DBusNodeInfo.new_for_xml(
    '<node><interface name="org.freedesktop.portal.RemoteDesktop">'
    '<property name="version" type="u" access="read"/></interface></node>').interfaces[0]
bus.register_object("/org/freedesktop/portal/desktop", remote_desktop, None, screen_property, None)
bus.call_sync("org.freedesktop.DBus", "/org/freedesktop/DBus", "org.freedesktop.DBus", "RequestName",
              GLib.Variant("(su)", ("org.freedesktop.portal.Desktop", 0)), None, 0, 5000, None)
client_env = os.environ.copy()
if "--confined" in sys.argv[2:]:
    launcher = runpy.run_path(str(Path(__file__).resolve().parents[1] / "serein-session.py"))
    client_env = launcher["environment"](launcher["APP"])
client = subprocess.Popen(sys.argv[1:], env=client_env)
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
assert len(requests) == 2 and selection_count == 3
