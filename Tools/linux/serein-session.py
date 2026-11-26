#!/usr/bin/python3
"""Run the installed Serein desktop and its socket-activated services in Docker."""
import os
from pathlib import Path
import resource
import selectors
import signal
import socket
import sys
import time

BIN = Path("/opt/serein/bin")
APP = "SignalSafe"
# These slots match Route in LinuxServiceTransport.swift. Slot 167 is private
# to the fetcher and parser, which use it for delegated HTML parsing.
SERVICES = {
    160: "SignalMediaDecoderService", 161: "SignalLinkPreviewParserService",
    162: "SignalLinkPreviewFetcherService", 163: "SignalGifSearchService",
    164: "SignalVoiceNoteEncoderService", 165: "SignalCallingService",
    166: "SignalMessageParserService",
}
# The Swift worker monitor reads /proc/<tid>/stat outside the confined filesystem.
PARSER_CHILD = "SignalMessageParserChild"
NO_WORKER_MONITOR = {APP, SERVICES[160], SERVICES[161], SERVICES[165], SERVICES[166], PARSER_CHILD}
RESTART_DESKTOP = 75
CONFIG_ERROR = 78


def environment(name):
    env = {"PATH": "/usr/bin:/bin", "LANG": os.environ.get("LANG", "C.UTF-8")}
    if name == APP:
        for key in ("DISPLAY", "XAUTHORITY", "WAYLAND_DISPLAY", "DBUS_SESSION_BUS_ADDRESS",
                    "LC_ALL", "LC_MESSAGES", "LC_CTYPE", "TZ"):
            if key in os.environ:
                env[key] = os.environ[key]
        env.update(HOME="/var/lib/serein", XDG_RUNTIME_DIR="/run/serein", TMPDIR="/run/serein",
                   QT_QPA_PLATFORMTHEME="xdgdesktopportal")
    else:
        env["HOME"] = "/nonexistent"
    if name in NO_WORKER_MONITOR:
        env["LD_LIBRARY_PATH"] = "/usr/local/lib/serein/workers"
    return env


def spawn(name, routes, arguments=()):
    # Every original socket is close-on-exec. Duplicate only this component's
    # capabilities into their designated slots. Give workers no terminal input.
    actions = [(os.POSIX_SPAWN_OPEN, 0, "/dev/null", os.O_RDONLY, 0)]
    if name == PARSER_CHILD:
        actions.append((os.POSIX_SPAWN_OPEN, 2, "/dev/null", os.O_WRONLY, 0))
    actions += [(os.POSIX_SPAWN_DUP2, endpoint.fileno(), slot) for slot, endpoint in routes.items()]
    binary = str(BIN / name)
    return os.posix_spawn(binary, [binary, *arguments], environment(name), file_actions=actions,
                          setpgroup=0, setsigdef=(signal.SIGPIPE, signal.SIGINT, signal.SIGTERM))


def signal_group(pid, sig):
    try:
        os.killpg(pid, sig)
    except ProcessLookupError:
        pass


def stop(children):
    # Stop the desktop and the workers with any helpers in their process groups.
    for pid in children:
        signal_group(pid, signal.SIGTERM)
    deadline = time.monotonic() + 2
    while children and time.monotonic() < deadline:
        for pid in list(children):
            if os.waitpid(pid, os.WNOHANG)[0]:
                signal_group(pid, signal.SIGKILL)
                children.remove(pid)
        if children:
            time.sleep(.02)
    for pid in children:
        signal_group(pid, signal.SIGKILL)
        os.waitpid(pid, 0)


class ParserChildren:
    """Start only the installed parser child. The supervisor never reads message data."""

    def __init__(self, watch):
        self.watch = watch
        self.leases = {}

    def accept(self, route):
        token, fds, flags, _ = socket.recv_fds(route, 16, 1, socket.MSG_DONTWAIT | socket.MSG_CMSG_CLOEXEC)
        if not token and not fds:
            self.watch.unregister(route)
            return
        if token != bytes(16) or flags & (socket.MSG_TRUNC | socket.MSG_CTRUNC) or len(fds) != 1 or len(self.leases) >= 16:
            for fd in fds:
                os.close(fd)
            return
        fd = fds[0]
        try:
            lease = socket.socket(fileno=fd)
        except OSError:
            os.close(fd)
            return
        pid = None
        try:
            if lease.family != socket.AF_UNIX or lease.getsockopt(socket.SOL_SOCKET, socket.SO_TYPE) != socket.SOCK_SEQPACKET:
                return
            lease.getpeername()
            lease.setblocking(False)
            client, child = socket.socketpair()
            with client, child:
                pid = spawn(PARSER_CHILD, {0: child, 1: child})
                self.leases[pid] = lease
                self.watch.register(lease, selectors.EVENT_READ, pid)
                if socket.send_fds(lease, [bytes(16)], [client.fileno()]) != 16:
                    self.cancel(pid)
        except OSError:
            if pid is not None:
                self.cancel(pid)
        finally:
            if pid is None:
                lease.close()

    def release(self, pid):
        lease = self.leases[pid]
        if lease is not None:
            self.watch.unregister(lease)
            lease.close()
            self.leases[pid] = None

    def cancel(self, pid):
        # A readable lease (including EOF) cancels this child only. The PID
        # is still our unreaped child, even if it has already exited.
        self.release(pid)
        signal_group(pid, signal.SIGKILL)

    def reap(self):
        for pid in list(self.leases):
            if os.waitpid(pid, os.WNOHANG)[0]:
                self.release(pid)
                del self.leases[pid]

    def close(self):
        for pid in self.leases:
            self.cancel(pid)
        for pid in self.leases:
            os.waitpid(pid, 0)
        self.leases.clear()


def session(arguments, stopping):
    app_routes = {}
    workers = {name: {} for name in SERVICES.values()}
    listeners = {name: [] for name in workers}
    children = set()
    running = {}
    retry_after = {}
    with selectors.DefaultSelector() as watch:
        parsers = ParserChildren(watch)
        parser_requests, workers[SERVICES[166]][168] = socket.socketpair(socket.AF_UNIX, socket.SOCK_SEQPACKET)
        watch.register(parser_requests, selectors.EVENT_READ)
        try:
            for slot, name in SERVICES.items():
                app_routes[slot], worker = socket.socketpair(socket.AF_UNIX, socket.SOCK_SEQPACKET)
                workers[name][slot] = worker
                listeners[name].append(worker)
            outgoing, incoming = socket.socketpair(socket.AF_UNIX, socket.SOCK_SEQPACKET)
            workers[SERVICES[162]][167] = outgoing
            workers[SERVICES[161]][167] = incoming
            listeners[SERVICES[161]].append(incoming)

            app = spawn(APP, app_routes, arguments)
            children.add(app)
            for endpoint in app_routes.values():
                endpoint.close()
            for name, endpoints in listeners.items():
                for endpoint in endpoints:
                    watch.register(endpoint, selectors.EVENT_READ, name)

            while not stopping():
                parsers.reap()
                ended, status = os.waitpid(app, os.WNOHANG)
                if ended:
                    children.remove(app)
                    code = os.waitstatus_to_exitcode(status)
                    return 128 - code if code < 0 else code
                for name, pid in list(running.items()):
                    ended, status = os.waitpid(pid, os.WNOHANG)
                    if not ended:
                        continue
                    children.remove(pid)
                    signal_group(pid, signal.SIGKILL)
                    del running[name]
                    code = os.waitstatus_to_exitcode(status)
                    if code == CONFIG_ERROR:
                        # A missing confinement profile must fail requests promptly.
                        print(f"Serein: {name} refused its configuration", file=sys.stderr)
                        for endpoint in workers[name].values():
                            endpoint.close()
                    else:
                        if code:
                            print(f"Serein: {name} exited with status {code}", file=sys.stderr)
                        retry_after[name] = time.monotonic() + (1 if code else 0)
                for name, deadline in list(retry_after.items()):
                    if time.monotonic() >= deadline:
                        for endpoint in listeners[name]:
                            watch.register(endpoint, selectors.EVENT_READ, name)
                        del retry_after[name]
                for key, _ in watch.select(timeout=.2):
                    if key.fileobj is parser_requests:
                        parsers.accept(parser_requests)
                        continue
                    if isinstance(key.data, int):
                        parsers.cancel(key.data)
                        continue
                    name = key.data
                    if name in running:
                        continue
                    # A closed peer also wakes the selector. Only a queued channel
                    # request should start a worker when the desktop is exiting.
                    try:
                        pending = key.fileobj.recv(1, socket.MSG_PEEK | socket.MSG_DONTWAIT)
                    except BlockingIOError:
                        continue
                    if not pending:
                        watch.unregister(key.fileobj)
                        listeners[name].remove(key.fileobj)
                        continue
                    for endpoint in listeners[name]:
                        watch.unregister(endpoint)
                    pid = spawn(name, workers[name])
                    children.add(pid)
                    running[name] = pid
            return 128 + stopping()
        finally:
            parser_requests.close()
            parsers.close()
            for routes in [app_routes, *workers.values()]:
                for endpoint in routes.values():
                    endpoint.close()
            stop(children)


def main():
    if os.getuid() == 0 or os.getuid() != os.geteuid():
        sys.exit("Serein's Docker session requires an unprivileged user.")
    for name in (APP, *SERVICES.values(), PARSER_CHILD):
        if not os.access(BIN / name, os.X_OK):
            print(f"Serein: missing executable {BIN / name}", file=sys.stderr)
            return CONFIG_ERROR
    # The Docker entry point accepts no inherited capabilities. Its sockets are
    # allocated below the reserved slots in a single-threaded supervisor.
    os.closerange(3, os.sysconf("SC_OPEN_MAX"))
    resource.setrlimit(resource.RLIMIT_CORE, (0, 0))
    requested = 0

    def stopping(sig, _frame):
        nonlocal requested
        requested = sig

    signal.signal(signal.SIGTERM, stopping)
    signal.signal(signal.SIGINT, stopping)
    while not requested:
        code = session(sys.argv[1:], lambda: requested)
        if code != RESTART_DESKTOP:
            return code
    return 128 + requested


if __name__ == "__main__":
    sys.exit(main())
