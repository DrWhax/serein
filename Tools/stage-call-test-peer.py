#!/usr/bin/env python3
"""Embed a signed, synthetic RingRTC participant in a signed Serein QA app."""
import argparse
import os
from pathlib import Path
import plistlib
import subprocess
import tempfile

from calling_reference import ROOT, build_reference, install_peer, peer_entitlements


def run(*args, **options):
    return subprocess.run(args, check=True, **options)


def get_entitlements(bundle):
    data = run("codesign", "-d", "--entitlements", ":-", bundle, capture_output=True).stdout
    entitlements = plistlib.loads(data)
    if entitlements.get("com.apple.security.app-sandbox") is not True:
        raise ValueError(f"Expected a sandboxed {bundle.name}")
    return entitlements


def stage(app, udp_port, tcp_port):
    contents = app.resolve(strict=True) / "Contents"
    info_file = contents / "Info.plist"
    info = plistlib.loads(info_file.read_bytes())
    app_ent = get_entitlements(app)
    if info["SereinXPCPeers"]["app"] != info["CFBundleIdentifier"]:
        raise ValueError("Missing signed app peer identity")
    # A shipping build compiles the test peer out. Only a QA build can host it.
    symbols = run("nm", contents / "MacOS" / info["CFBundleExecutable"], capture_output=True, text=True).stdout
    if "testPeerFactory" not in symbols:
        raise ValueError("This app was built without the test peer: rebuild it with SEREIN_QA_CALL_PEER=1 Tools/build-app.sh")
    identity = os.environ.get("SIGNALSAFE_SIGN_IDENTITY", "-")
    if info.get("SereinXPCSameTeam") and identity == "-":
        raise ValueError("Set SIGNALSAFE_SIGN_IDENTITY to this QA app's signing identity")
    sign = ["codesign", "--force", "--sign", identity, "--options", "runtime", "--timestamp=none"]
    profile = ROOT / "Packages/SignalMediaService/Sandbox/SignalCalling.sb"
    base = plistlib.loads(run(ROOT / "Tools/sbpl-entitlements.sh", profile, capture_output=True).stdout)
    peer_ent = peer_entitlements(base, udp_port, tcp_port)
    if identity == "-":
        peer_ent["com.apple.security.cs.disable-library-validation"] = True
    build_reference()
    install_peer(app, peer_ent, sign, "This is your local Ring R T C test peer.", 3)
    with tempfile.TemporaryDirectory(prefix="serein-test-peer-") as directory:
        work = Path(directory)
        app_plist = work / "app.entitlements"
        app_plist.write_bytes(plistlib.dumps(app_ent))
        run(*sign, "--entitlements", app_plist, app)
        run("codesign", "--verify", "--deep", "--strict", app)


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("app", type=Path, help="Sandboxed QA app to stage and re-sign in place")
    parser.add_argument("--local-sfu-udp-port", type=int)
    parser.add_argument("--local-sfu-tcp-port", type=int)
    args = parser.parse_args()
    stage(args.app, args.local_sfu_udp_port, args.local_sfu_tcp_port)
