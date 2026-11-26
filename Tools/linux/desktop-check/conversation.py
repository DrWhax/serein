"""Link the release executable to Signal's local test server and verify a round-trip message."""
import argparse
import importlib.util
import json
import os
from pathlib import Path
import signal
import subprocess
import sys
import tempfile
import time

from PIL import ImageGrab
from capture import application_window, xdo

REPLY = "Reply from Serein on Linux"


def run_supervisor(ready):
    spec = importlib.util.spec_from_file_location("supervisor", "/opt/serein/serein-session.py")
    launcher = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(launcher)
    normal_environment = launcher.environment

    def environment(name):
        env = normal_environment(name)
        if name == launcher.APP:
            env.update(SIGNALSAFE_MOCK_READY=str(ready), SIGNALSAFE_MOCK_REPLY=REPLY)
        return env

    # Only the test desktop uses the existing mock-client switch. Worker environments,
    # role descriptors, process startup and kernel confinement are the installed ones.
    launcher.environment = environment
    sys.argv = sys.argv[:1]
    return launcher.main()


def capture(found, output):
    if application_window() != found:
        raise RuntimeError("The original SignalSafe window closed")
    window, pid = found
    bounds = dict(line.split("=", 1) for line in xdo("getwindowgeometry", "--shell", window).splitlines())
    x, y, width, height = (int(bounds[key]) for key in ("X", "Y", "WIDTH", "HEIGHT"))
    frame = ImageGrab.grab(bbox=(x, y, x + width, y + height), xdisplay=os.environ["DISPLAY"])
    frame.save(output)
    print(f"Captured {output.name} from /opt/serein/bin/SignalSafe PID {pid} at {width} by {height}", flush=True)


def conversation(harness, output):
    if os.getuid() == 0:
        raise RuntimeError("The desktop check requires an unprivileged user")
    output.mkdir(parents=True, exist_ok=True)
    with tempfile.TemporaryDirectory(dir="/run/serein") as tmp, subprocess.Popen(
        ["node", str(harness)], cwd=harness.parent, stdin=subprocess.PIPE, stdout=subprocess.PIPE, text=True
    ) as server:
        try:
            ready = Path(tmp, "ready.json")
            startup = server.stdout.readline()
            if not json.loads(startup).get("port"):
                raise RuntimeError("The test server failed to publish its loopback endpoint")
            ready.write_text(startup)
            next_id = 0

            def call(command, **args):
                nonlocal next_id
                next_id += 1
                server.stdin.write(json.dumps(dict(id=next_id, cmd=command, **args)) + "\n")
                server.stdin.flush()
                for line in server.stdout:
                    response = json.loads(line)
                    if response.get("id") == next_id:
                        if not response["ok"]:
                            raise RuntimeError(f"{command} failed: {response['error']}")
                        return response["result"]
                raise RuntimeError("The test server exited early")

            with subprocess.Popen([sys.executable, __file__, "--supervise", str(ready)]) as desktop:
                try:
                    uri = Path(str(ready) + ".url")
                    while not uri.is_file() or not (found := application_window()):
                        if desktop.poll() is not None:
                            raise RuntimeError(f"Desktop exited with {desktop.returncode}")
                        time.sleep(.1)
                    xdo("windowfocus", "--sync", found[0])
                    xdo("windowsize", "--sync", found[0], "1100", "700")
                    call("provision", url=uri.read_text())
                    call("sendText", **{"from": "alice", "text": "Hello from the test phone",
                                       "timestamp": int(time.time() * 1000)})
                    for _ in range(3):
                        reply = call("waitForMessage", account="alice", timeout=30000)
                        if reply.get("body"):
                            break
                    if reply.get("body") != REPLY:
                        raise RuntimeError("The test phone did not receive the expected composer reply")
                    time.sleep(.5)
                    capture(found, output / "conversation.png")
                    xdo("key", "ctrl+comma")
                    time.sleep(.5)
                    capture(found, output / "settings.png")
                    print("The linked desktop received a message and the test phone verified the reply.")
                finally:
                    desktop.terminate()
                    desktop.wait(timeout=12)
        finally:
            server.terminate()


if __name__ == "__main__":
    if len(sys.argv) == 3 and sys.argv[1] == "--supervise":
        sys.exit(run_supervisor(Path(sys.argv[2])))
    cli = argparse.ArgumentParser(description=__doc__)
    cli.add_argument("harness", type=Path)
    cli.add_argument("output", type=Path)
    args = cli.parse_args()

    def timed_out(signum, frame):
        raise TimeoutError("Device linking or message delivery timed out")

    signal.signal(signal.SIGALRM, timed_out)
    signal.alarm(120)
    conversation(args.harness.resolve(), args.output.resolve())
