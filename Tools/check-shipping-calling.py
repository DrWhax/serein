#!/usr/bin/env python3
"""Verify the signed Serein distribution and its separation from native calling fixtures."""
import argparse
from pathlib import Path
import re
import subprocess


# Include weak/re-exported libraries and embedded rpaths as well as normal dependencies.
NATIVE_PATH = re.compile(
    r"(?:^|/)(?:lib(?:signal_ringrtc|ringrtc|webrtc)(?:[./_]|$)|(?:WebRTC|RingRTC)\.(?:xc)?framework(?:/|$)"
    r"|SignalCallTestPeer(?:Service)?(?:[./]|$)|(?:lib)?(?:CSignalRingRTC|RingRTCNative|SignalCallingInterop)(?:[./-]|$)"
    r"|vendor/ringrtc/|Packages/SignalRingRTC/rust/)", re.IGNORECASE)
NATIVE_SYMBOL = re.compile(
    r"\$s(?:13RingRTCNative|20SignalCallingInterop)|(?:^|\s)_srr_|(?:^|\s)_Rust_createPeerConnection|(?:^|\s)_WebRtc[A-Z]"
    r"|__Z\w*6webrtc[0-9]|__ZNK?3rtc[0-9]|_OBJC_CLASS_\$_RTCPeerConnection\b")
MACH_O = {bytes.fromhex(m) for m in ("feedface", "cefaedfe", "feedfacf", "cffaedfe",
                                      "cafebabe", "bebafeca", "cafebabf", "bfbafeca")}


def inspect_link_map(link_map):
    objects = []
    for line in link_map.read_text().splitlines():
        if line == "# Sections:":
            break
        if line.startswith("["):
            objects.append(line.split("]", 1)[1].strip())
    if not any(Path(obj).name == "SwiftCalling.o" for obj in objects):
        raise SystemExit(f"SwiftCalling.o is missing from the calling service link map: {link_map}")
    for obj in objects:
        if NATIVE_PATH.search(obj):
            raise SystemExit(f"Native calling object in the calling service link map: {obj}")


def inspect_bundle(app):
    subprocess.run(["codesign", "--verify", "--deep", "--strict", app], check=True)
    service = app / "Contents/XPCServices/SignalCalling.xpc/Contents/MacOS/SignalCalling"
    if not service.is_file():
        raise SystemExit(f"Missing production calling service in {app}")
    count = 0
    for path in app.rglob("*"):
        if NATIVE_PATH.search(path.relative_to(app).as_posix()):
            raise SystemExit(f"Native calling artifact in distribution: {path}")
        if path.is_symlink() or not path.is_file():
            continue
        with path.open("rb") as stream:
            magic = stream.read(8)
        if magic[:4] in MACH_O:
            count += 1
            commands = subprocess.check_output(["otool", "-arch", "all", "-l", path], text=True)
            for line in commands.splitlines():
                fields = line.strip().split(" ", 1)
                if fields[0] in {"name", "path"} and len(fields) == 2 and NATIVE_PATH.search(fields[1]):
                    raise SystemExit(f"Native calling load command in {path}: {line.strip()}")
        elif magic != b"!<arch>\n":
            continue
        symbols = subprocess.check_output(["nm", "-arch", "all", "-j", path], text=True)
        match = NATIVE_SYMBOL.search(symbols)
        if match:
            raise SystemExit(f"Native calling symbol in {path}: {match.group().strip()}")
    print(f"Verified signed app and checked {count} Mach-O files for native WebRTC and RingRTC")


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("app", type=Path)
    parser.add_argument("--link-map", type=Path, help="production calling service linker map from build-app.sh")
    args = parser.parse_args()
    if args.link_map:
        inspect_link_map(args.link_map)
    inspect_bundle(args.app)
