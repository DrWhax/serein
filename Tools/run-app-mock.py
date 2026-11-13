#!/usr/bin/env python3 -I
"""Runs the built SignalSafe.app against the local @signalapp/mock-server (no Signal servers).

Starts Tests/MockServer/harness.mjs, launches the app with SIGNALSAFE_MOCK_READY, links it as
the mock primary's new device by "scanning" the QR URL the app writes, then has Alice send a
text and a PNG. Leaves the app running for --seconds, takes a screenshot, and quits.

  Tools/build-app.sh && Tools/run-app-mock.py --seconds 20 --screenshot /path/out.png
"""
import argparse, base64, json, os, struct, subprocess, sys, tempfile, time, zlib

root = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
parser = argparse.ArgumentParser()
parser.add_argument("--seconds", type=float, default=20)
parser.add_argument("--screenshot")
parser.add_argument("--video", help="an MP4 Alice also sends; the app opens it in the Lightbox")
parser.add_argument("--key-change", action="store_true", help="Alice then re-installs and writes again: the chat shows the safety number notice")
args = parser.parse_args()

def png(w, h):
    # A diagonal gradient, so scaling and orientation are visible.
    raw = b"".join(b"\0" + b"".join(bytes((x * 255 // w, y * 255 // h, 200)) for x in range(w)) for y in range(h))
    chunk = lambda t, d: struct.pack(">I", len(d)) + t + d + struct.pack(">I", zlib.crc32(t + d) & 0xFFFFFFFF)
    return b"\x89PNG\r\n\x1a\n" + chunk(b"IHDR", struct.pack(">IIBBBBB", w, h, 8, 2, 0, 0, 0)) + chunk(b"IDAT", zlib.compress(raw)) + chunk(b"IEND", b"")

# The app is sandboxed: it reads the server's details and writes the QR URL only inside its
# container (macOS creates it at the first sandboxed launch).
container_tmp = os.path.expanduser("~/Library/Containers/org.signalsafe.SignalSafe/Data/tmp")
work = tempfile.mkdtemp(prefix="signalsafe-mock-", dir=container_tmp if os.path.isdir(container_tmp) else None)
ready_path = os.path.join(work, "ready.json")
harness = subprocess.Popen(["node", "harness.mjs"], cwd=os.path.join(root, "Tests/MockServer"), stdin=subprocess.PIPE,
                           stdout=subprocess.PIPE, text=True, bufsize=1)
ready = harness.stdout.readline()
open(ready_path, "w").write(ready)
print("mock server on port", json.loads(ready)["port"])
next_id = 0
def call(cmd, **kw):
    global next_id
    next_id += 1
    harness.stdin.write(json.dumps({"id": next_id, "cmd": cmd, **kw}) + "\n")
    harness.stdin.flush()
    while True:
        r = json.loads(harness.stdout.readline())
        if r.get("id") == next_id:
            if not r["ok"]: raise RuntimeError(f"{cmd}: {r['error']}")
            return r["result"]

def capture(path):
    # Only the app's window (never the whole screen): its id from CGWindowList.
    finder = 'import CoreGraphics\nlet l = CGWindowListCopyWindowInfo([.optionOnScreenOnly], kCGNullWindowID) as? [[String: Any]] ?? []\n' \
             'for w in l where (w["kCGWindowOwnerPID"] as? Int) == Int(CommandLine.arguments[1])! && (w["kCGWindowLayer"] as? Int) == 0 ' \
             '{ print(w["kCGWindowNumber"] as! Int); break }\n'
    wid = subprocess.run(["swift", "-e", finder, str(app.pid)], capture_output=True, text=True).stdout.strip()
    if wid:
        subprocess.run(["screencapture", "-x", "-o", "-l" + wid, path])
        print("screenshot:", path)
    else:
        print("no app window found for a screenshot")

app_bin = os.path.join(root, "App/SignalSafe/.build/Serein.app/Contents/MacOS/Serein")
log = open(os.path.join(work, "app.log"), "w")
reply = "Reply from SignalSafe ✅"
extra = {"SIGNALSAFE_MOCK_LIGHTBOX": "1"} if args.video else {}
second = "Is this really you?"
if args.key_change: extra["SIGNALSAFE_MOCK_KEYCHANGE_REPLY"] = second
app = subprocess.Popen([app_bin], env={**os.environ, "SIGNALSAFE_MOCK_READY": ready_path, "SIGNALSAFE_MOCK_REPLY": reply, **extra},
                       stdout=log, stderr=log)
try:
    url_path = ready_path + ".url"
    for _ in range(300):
        if os.path.exists(url_path): break
        time.sleep(0.1)
    else:
        sys.exit("app never showed a QR code; log: " + log.name)
    url = open(url_path).read()
    print("QR:", url[:60] + "…")
    call("provision", url=url)
    print("linked")
    time.sleep(3)
    now = int(time.time() * 1000)
    call("sendText", **{"from": "alice", "text": "Hi from Alice 👋 (mock server)", "timestamp": now})
    call("sendAttachment", **{"from": "alice", "data": base64.b64encode(png(480, 320)).decode(), "contentType": "image/png",
                              "timestamp": now + 1})
    if args.video:
        call("sendAttachment", **{"from": "alice", "data": base64.b64encode(open(args.video, "rb").read()).decode(), "contentType": "video/mp4",
                                  "timestamp": now + 2})
    print("alice sent a text and a PNG" + (" and a video" if args.video else ""))
    # Accepting the message request first sends Alice an empty profile-key update.
    for _ in range(3):
        got = call("waitForMessage", account="alice", timeout=20000)
        if got["body"]: break
    print("alice received:", repr(got["body"]), "ok" if got["body"] == reply else "MISMATCH")
    if args.key_change:
        call("reregister", account="alice", openSession=True)
        call("sendText", **{"from": "alice", "text": "New phone, same Alice", "timestamp": int(time.time() * 1000)})
        print("alice re-installed and wrote again")
        # The app answers through its composer: the safety number review must come first.
        time.sleep(4)
        if args.screenshot: capture(args.screenshot.replace(".png", "-review.png"))
        got = call("waitForMessage", account="alice", timeout=30000)
        print("after confirming the review alice received:", repr(got["body"]), "ok" if got["body"] == second else "MISMATCH")
    time.sleep(args.seconds)
    services = subprocess.run(["pgrep", "-fl", "SignalMediaDecoder"], capture_output=True, text=True).stdout.strip()
    print("media service:", services or "not running")
    if args.screenshot: capture(args.screenshot)
finally:
    app.terminate()
    try: app.wait(5)
    except subprocess.TimeoutExpired: app.kill()
    harness.stdin.close()
    harness.wait(10)
    print("log:", log.name)
