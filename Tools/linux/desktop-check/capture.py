"""Capture the running SignalSafe window from X11 in a fresh Docker desktop session."""
import os
from pathlib import Path
import signal
import subprocess
import sys
import time

from PIL import ImageGrab

def xdo(*args):
    return subprocess.check_output(["xdotool", *args], text=True, stderr=subprocess.DEVNULL, timeout=3).strip()

def application_window():
    try:
        windows = xdo("search", "--onlyvisible", "--name", ".").splitlines()
    except subprocess.CalledProcessError:
        return None
    for window in windows:
        try:
            pid = int(xdo("getwindowpid", window))
            command = Path(f"/proc/{pid}/cmdline").read_bytes().split(b"\0")[0]
            if command == b"/opt/serein/bin/SignalSafe":
                return window, pid
        except (subprocess.CalledProcessError, OSError, ValueError):
            continue
    return None

def main(output):
    if os.getuid() == 0:
        raise RuntimeError("Run the desktop check as the image's serein user")
    # An isolated, initially empty Secret Service login collection.
    # The check's passphrase and home are local to this disposable container.
    subprocess.run(["gnome-keyring-daemon", "--unlock", "--components=secrets"],
                   input=os.urandom(32).hex().encode(), check=True, stdout=subprocess.DEVNULL)
    supervisor = subprocess.Popen(["python3", "/opt/serein/serein-session.py"])
    try:
        deadline = time.monotonic() + 45
        while time.monotonic() < deadline and supervisor.poll() is None:
            found = application_window()
            if found:
                break
            time.sleep(0.1)
        else:
            raise RuntimeError(f"SignalSafe did not open a window (supervisor status {supervisor.poll()})")
        window, pid = found
        xdo("windowfocus", "--sync", window)
        time.sleep(1.2)
        if application_window() != found:
            raise RuntimeError("The original SignalSafe window closed")
        geometry = dict(line.split("=", 1) for line in xdo("getwindowgeometry", "--shell", window).splitlines())
        x, y, width, height = (int(geometry[field]) for field in ("X", "Y", "WIDTH", "HEIGHT"))
        if width < 300 or height < 200:
            raise RuntimeError(f"Unexpected window size {width} by {height}")
        bounds = (x, y, x + width, y + height)
        image = ImageGrab.grab(bbox=bounds, xdisplay=os.environ["DISPLAY"])
        if max(channel[1] - channel[0] for channel in image.getextrema()[:3]) < 30:
            raise RuntimeError("The window is blank")
        database = Path.home() / ".local/share/signal-safe/db.sqlite"
        with database.open("rb") as stream:
            header = stream.read(16)
        if len(header) != 16 or header == b"SQLite format 3\0":
            raise RuntimeError("Expected an initialized SQLCipher database")
        if not (Path.home() / ".local/share/keyrings/login.keyring").is_file():
            raise RuntimeError("The desktop keyring was not created")
        image.save(output, format="PNG")
        print(f"Captured PID {pid}, /opt/serein/bin/SignalSafe, {width} by {height}.")
    finally:
        if supervisor.poll() is None:
            supervisor.send_signal(signal.SIGTERM)
        supervisor.wait(timeout=15)

if __name__ == "__main__":
    main(sys.argv[1])
