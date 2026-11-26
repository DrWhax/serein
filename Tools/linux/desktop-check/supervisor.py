"""Run as an unprivileged Linux user to check the Docker launcher's lifecycle."""
import importlib.util
import os
from pathlib import Path
import socket
import subprocess
import sys
import tempfile


def fixture():
    role = Path(sys.argv[0]).name
    folder = Path(sys.argv[0]).parent
    if role == "SessionLaunchCheck":
        for slot in range(160, 167):
            with socket.fromfd(slot, socket.AF_UNIX, socket.SOCK_SEQPACKET) as route:
                assert route.getsockopt(socket.SOL_SOCKET, socket.SO_TYPE) == socket.SOCK_SEQPACKET
        assert all(not Path(f"/proc/self/fd/{slot}").exists() for slot in (167, 168))
        started = folder / "restarted"
        if not started.exists():
            started.touch()
            return 75
        with socket.fromfd(160, socket.AF_UNIX, socket.SOCK_SEQPACKET) as route:
            route.settimeout(5)
            route.send(b"ping")
            assert route.recv(4) == b"pong"
        with socket.fromfd(166, socket.AF_UNIX, socket.SOCK_SEQPACKET) as messages:
            messages.settimeout(5)
            messages.send(b"parse")
            assert messages.recv(2) == b"ok"
        return 0
    if role == "SignalMessageParserService":
        with socket.fromfd(166, socket.AF_UNIX, socket.SOCK_SEQPACKET) as app, socket.fromfd(168, socket.AF_UNIX, socket.SOCK_SEQPACKET) as broker:
            assert app.recv(5) == b"parse"
            def start():
                lease, request = socket.socketpair(socket.AF_UNIX, socket.SOCK_SEQPACKET)
                with request:
                    socket.send_fds(broker, [bytes(16)], [request.fileno()])
                lease.settimeout(3)
                token, fds, flags, _ = socket.recv_fds(lease, 16, 1)
                assert token == bytes(16) and len(fds) == 1
                stream = socket.socket(fileno=fds[0])
                stream.settimeout(3)
                return lease, stream
            first, first_stream = start()
            second, second_stream = start()
            with first, first_stream, second, second_stream:
                first_stream.sendall(b"busy")
                assert first_stream.recv(4) == b"busy"
                first.close()
                assert first_stream.recv(1) == b""
                second_stream.sendall(b"ping")
                assert second_stream.recv(4) == b"ping"
            app.send(b"ok")
        return 0
    if role == "SignalMessageParserChild":
        assert all(not Path(f"/proc/self/fd/{slot}").exists() for slot in range(160, 169))
        data = os.read(0, 4)
        os.write(1, data)
        if data == b"busy":
            import time
            time.sleep(60)
        return 0
    if role == "SignalMediaDecoderService":
        assert all(not Path(f"/proc/self/fd/{slot}").exists() for slot in range(161, 169))
        with socket.fromfd(160, socket.AF_UNIX, socket.SOCK_SEQPACKET) as route:
            assert route.recv(4) == b"ping"
            route.send(b"pong")
        return 0
    (folder / "unexpected-worker").write_text(role)
    return 1


if Path(sys.argv[0]).name != "supervisor.py":
    sys.exit(fixture())

launcher = Path(__file__).resolve().parents[1] / "serein-session.py"
spec = importlib.util.spec_from_file_location("serein_session", launcher)
module = importlib.util.module_from_spec(spec)
spec.loader.exec_module(module)
if len(sys.argv) == 2:
    module.BIN = Path(sys.argv[1])
    module.APP = "SessionLaunchCheck"
    sys.exit(module.main())

with tempfile.TemporaryDirectory() as work:
    folder = Path(work)
    # Synthetic processes check descriptor inheritance and activation; no GUI is used.
    executable = folder / "fixture"
    executable.write_text("#!/usr/bin/python3\n" + Path(__file__).read_text())
    executable.chmod(0o755)
    for name in ("SessionLaunchCheck", *module.SERVICES.values(), "SignalMessageParserChild"):
        (folder / name).symlink_to(executable)
    subprocess.run([sys.executable, __file__, work], check=True, timeout=12)
    assert (folder / "restarted").exists() and not (folder / "unexpected-worker").exists()
print("PASS: desktop relaunch, per-role descriptors, on-demand activation, isolated parser lifetimes and clean shutdown")
