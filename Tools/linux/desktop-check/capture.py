"""Capture the running SignalSafe window from X11 in a fresh Docker desktop session."""
import os
from pathlib import Path
import signal
import subprocess
import time

from PIL import ImageGrab

def xdo(*args):
    return subprocess.check_output(["xdotool", *args], text=True, stderr=subprocess.DEVNULL, timeout=3).strip()

def application_window(*, title=None):
    try:
        windows = xdo("search", "--onlyvisible", "--name", ".").splitlines()
    except subprocess.CalledProcessError:
        return None
    for window in windows:
        try:
            pid = int(xdo("getwindowpid", window))
            command = Path(f"/proc/{pid}/cmdline").read_bytes().split(b"\0")[0]
            if command == b"/opt/serein/bin/SignalSafe" and (title is None or xdo("getwindowname", window) == title):
                return window, pid
        except (subprocess.CalledProcessError, OSError, ValueError):
            continue
    return None

def main(output, about=False):
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
        if about:
            # With the default English locale, the window menu order is File, Edit, View, Window, Help.
            # Open File with the pointer, then traverse the actual menu bar to Help > About.
            xdo("mousemove", "--window", window, "13", "10", "click", "1")
            xdo("key", "--delay", "120", "Right", "Right", "Right", "Right", "Down", "Return")
            deadline = time.monotonic() + 8
            while time.monotonic() < deadline:
                secondary = application_window(title="About Serein")
                if secondary and secondary[1] == pid and secondary[0] != window:
                    break
                time.sleep(0.1)
            else:
                raise RuntimeError("Help > About did not open a second SignalSafe window")
            primary = window
            window = secondary[0]
            xdo("windowfocus", "--sync", window)
            time.sleep(0.3)
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
        if about:
            xdo("key", "Escape")
            deadline = time.monotonic() + 5
            while time.monotonic() < deadline and application_window(title="About Serein"):
                time.sleep(0.1)
            if application_window() != (primary, pid) or application_window(title="About Serein"):
                raise RuntimeError("Dismissing About did not restore the main window")
        print(f"Captured PID {pid}, /opt/serein/bin/SignalSafe, {width} by {height}.")
    finally:
        if supervisor.poll() is None:
            supervisor.send_signal(signal.SIGTERM)
        supervisor.wait(timeout=15)

if __name__ == "__main__":
    import argparse
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("output")
    parser.add_argument("--about", action="store_true")
    args = parser.parse_args()
    main(args.output, args.about)
