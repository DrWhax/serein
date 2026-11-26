"""Drive the production calling service over the app's inherited Linux IPC route."""
import os
from pathlib import Path
import signal
import socket
import sys
import time

if os.geteuid() == 0:
    sys.exit("Run this check as an unprivileged user.")
folder = Path(sys.argv[1])
a, b = socket.socketpair(socket.AF_UNIX, socket.SOCK_SEQPACKET)
env = {"PATH": "/usr/bin:/bin", "HOME": "/nonexistent", "LANG": "C",
       "LD_LIBRARY_PATH": "/usr/local/lib/serein/workers"}
if len(sys.argv) > 2:
    env["ALSA_CONFIG_PATH"] = sys.argv[2]
relay = os.environ.get("SEREIN_TEST_TURN_HOST")
check = ["--devices"]
client_env = env.copy()
if relay:
    check = ["--staged-video"]
    for key in ("SEREIN_TEST_TURN_HOST", "SEREIN_TEST_TURN_PORT", "SEREIN_TEST_TURN_TRANSPORT"):
        if key in os.environ:
            client_env[key] = os.environ[key]
children = set()
service_pid = None
try:
    for name, channel, args in (("SignalCallingService", b, []), ("CallServiceCheck", a, check)):
        binary = str(folder / name)
        pid = os.posix_spawn(binary, [binary, *args], client_env if channel is a else env, setpgroup=0,
                             file_actions=[(os.POSIX_SPAWN_DUP2, channel.fileno(), 165)])
        children.add(pid)
        if channel is b:
            service_pid = pid
            b.close()  # The desktop keeps its service route until the session has closed.
    deadline = time.monotonic() + (100 if relay else 30)
    while children and time.monotonic() < deadline:
        for pid in list(children):
            ended, status = os.waitpid(pid, os.WNOHANG)
            if ended:
                children.remove(pid)
                if os.waitstatus_to_exitcode(status):
                    sys.exit(f"Calling process {pid} exited with {os.waitstatus_to_exitcode(status)}")
        time.sleep(.02)
    if children:
        sys.exit("Timed out waiting for the calling session to end.")
    try:
        os.killpg(service_pid, 0)
    except ProcessLookupError:
        pass
    else:
        sys.exit("The calling service left a socket broker running after hang-up.")
finally:
    a.close()
    b.close()
    for pid in children:
        try:
            os.killpg(pid, signal.SIGKILL)
        except ProcessLookupError:
            pass
        os.waitpid(pid, 0)
