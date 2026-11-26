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
        assert not Path("/proc/self/fd/167").exists()
        started = folder / "restarted"
        if not started.exists():
            started.touch()
            return 75
        with socket.fromfd(160, socket.AF_UNIX, socket.SOCK_SEQPACKET) as route:
            route.settimeout(5)
            route.send(b"ping")
            assert route.recv(4) == b"pong"
        return 0
    if role == "SignalMediaDecoderService":
        assert all(not Path(f"/proc/self/fd/{slot}").exists() for slot in range(161, 168))
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
print("PASS: desktop relaunch, per-role descriptors, on-demand activation and clean shutdown")
