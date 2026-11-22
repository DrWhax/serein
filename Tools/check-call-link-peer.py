#!/usr/bin/env python3
"""Verify bidirectional video between a signed Serein host and a native RingRTC call-link peer.

Run inside Tools/with-calling-frontend.py with --backend and the mock server's zk-params.
Build the ad-hoc Serein app and the mock server first, as for Tools/run-app-mock.py.
Two linked devices of the owner and an independent guest use a single loopback SFU.
Only the share URL passes from the owner to the guest. All devices use silent output
and disabled camera and microphone inputs. The owner shares the fixture's own window.
"""
import argparse
from contextlib import contextmanager, ExitStack
import json
import os
from pathlib import Path
import plistlib
import select
import shlex
import shutil
import subprocess
import sys
import tempfile
import time

ROOT = Path(__file__).resolve().parents[1]
APP = ROOT / "App/SignalSafe"
RTC = ROOT / "Packages/SignalRingRTC"
FIXTURES = ROOT / "Tools/calling-sfu"
IDENTIFIER = "org.signalsafe.LocalPeerFixture"


def run(*args, **kwargs):
    return subprocess.run(args, check=True, **kwargs)


def linked_objects(path):
    return [p for p in shlex.split(path.read_text()) if "/Products/" in p]


def build_hosts(work):
    def build(*args):
        log = work / "build.log"
        with log.open("w") as output:
            command = subprocess.run(args, stdout=output, stderr=subprocess.STDOUT)
        if command.returncode:
            print("\n".join(log.read_text(errors="replace").splitlines()[-25:]), file=sys.stderr)
            command.check_returncode()

    build("swift", "build", "--package-path", APP, "--build-tests")
    build("swift", "build", "--package-path", RTC, "-c", "release", "--product", "SignalCallingService")
    common = ["xcrun", "swiftc", "-swift-version", "6", "-strict-memory-safety", "-warnings-as-errors",
              "-target", "arm64-apple-macos27.0", "-parse-as-library", "-module-cache-path", work / "modules",
              "-Xlinker", "-rpath", "-Xlinker", "@executable_path/../Frameworks"]
    out = APP / ".build/out"
    products = out / "Products/Debug"
    objects = out / "Intermediates.noindex/SignalSafe.build/Debug"
    module, = objects.glob("SignalSafe-*-testable-t.build/Objects-normal/arm64")
    files = objects / "SignalSafeTests-p.build/Objects-normal/arm64/SignalSafeTests.LinkFileList"
    build(*common, "-I", module, "-I", products, "-F", products,
        "-I", ROOT / "vendor/libsignal/swift/Sources/SignalFfi",
        "-I", ROOT / "vendor/GRDB.swift/Sources/GRDBSQLCipher/include",
        "-L", ROOT / "vendor/libsignal/target/aarch64-apple-darwin/release", "-lsignal_ffi", "-lc++",
        FIXTURES / "call-link-test-peer.swift", FIXTURES / "screen-share-window.swift",
        *linked_objects(files), "-o", work / "host")

    out = RTC / ".build/out"
    products = out / "Products/Release"
    intermediates = out / "Intermediates.noindex"
    files = intermediates / "SignalRingRTC.build/Release/SignalCallingService-p.build/Objects-normal/arm64/SignalCallingService.LinkFileList"
    build(*common, "-package-name", "signalringrtc", "-I", products, "-F", products,
        FIXTURES / "silent-calling-service.swift", *linked_objects(files), "-o", work / "SignalCalling")


def stage_fixture(source, work, udp, tcp):
    bundle = work / "SereinPeerFixture.app"
    run("/usr/bin/ditto", source, bundle)
    for item in [*sorted((bundle / "Contents/XPCServices").glob("*.xpc")), bundle]:
        plist = item / "Contents/Info.plist"
        info = plistlib.loads(plist.read_bytes())
        if info.get("SereinXPCSameTeam"):
            raise ValueError("Build an ad hoc QA app for the local peer check")
        info["SereinXPCPeers"]["app"] = IDENTIFIER
        ent = plistlib.loads(run("codesign", "-d", "--entitlements", ":-", source / item.relative_to(bundle),
                                  capture_output=True).stdout)
        if item == bundle or item.name == "SignalCalling.xpc":
            for key in ["com.apple.security.device.audio-input", "com.apple.security.device.camera"]:
                ent.pop(key, None)
        if item == bundle:
            info.update(CFBundleIdentifier=IDENTIFIER, CFBundleDisplayName="Serein Local Peer Fixture")
            shutil.copy2(work / "host", item / "Contents/MacOS/Serein")
        if item.name == "SignalCallTestPeer.xpc":
            # The source may already contain its optional peer. Retarget that copy
            # before the staging tool replaces it with this fixture's fresh build.
            source_id = plistlib.loads((source / "Contents/Info.plist").read_bytes())["CFBundleIdentifier"]
            if info.get("CFBundleIdentifier") != source_id + ".call-test-peer":
                raise ValueError("Unexpected test peer in the source app")
            info["CFBundleIdentifier"] = IDENTIFIER + ".call-test-peer"
        if item.name == "SignalCalling.xpc":
            shutil.copy2(work / "SignalCalling", item / "Contents/MacOS/SignalCalling")
            rules = ent["com.apple.security.temporary-exception.sbpl"]
            i = rules.index('(deny network-outbound (remote ip "localhost:*"))')
            rules[i:i+1] = [f'(allow network-outbound (remote udp "localhost:{udp}"))',
                            f'(allow network-outbound (remote tcp "localhost:{tcp}"))']
            ent.pop("com.apple.security.network.client", None)
        plist.write_bytes(plistlib.dumps(info))
        profile = work / "entitlements.plist"
        profile.write_bytes(plistlib.dumps(ent))
        run("codesign", "--force", "--sign", "-", "--options", "runtime", "--timestamp=none",
            "--entitlements", profile, item)
    run(sys.executable, ROOT / "Tools/stage-call-test-peer.py", bundle,
        "--local-sfu-udp-port", str(udp), "--local-sfu-tcp-port", str(tcp))
    run("codesign", "--verify", "--deep", "--strict", bundle)
    return bundle / "Contents/MacOS/Serein"


def stop(process):
    if process.poll() is None:
        process.terminate()
        try:
            process.wait(4)
        except subprocess.TimeoutExpired:
            process.kill()
            process.wait()


def wait_for(predicate, seconds):
    deadline = time.monotonic() + seconds
    while not predicate():
        if time.monotonic() > deadline:
            raise TimeoutError("Timed out waiting for local call-link fixture")
        time.sleep(0.1)


def read_reply(server):
    if not select.select([server.stdout], [], [], 30)[0]:
        raise TimeoutError("Timed out waiting for the local mock server")
    return json.loads(server.stdout.readline())


@contextmanager
def account():
    server = subprocess.Popen(["node", "--require", FIXTURES / "mock-frontend.cjs", "harness.mjs"],
                              cwd=ROOT / "Tests/MockServer", stdin=subprocess.PIPE, stdout=subprocess.PIPE,
                              stderr=subprocess.DEVNULL, text=True)
    try:
        ready = read_reply(server)
        if ready.get("event") != "ready":
            raise RuntimeError("Mock server did not emit its ready event")
        yield server, ready
        server.stdin.close()
        server.wait(10)
    finally:
        stop(server)


@contextmanager
def device(host, work, container, account_info, role, link=None, present_device=None):
    server, ready = account_info
    with ExitStack() as stack:
        shared = Path(stack.enter_context(tempfile.TemporaryDirectory(prefix="peer-call-", dir=container)))
        config = shared / "ready.json"
        config.write_text(json.dumps(ready))
        path = work / (role + ".log")
        log = stack.enter_context(path.open("w"))
        args = [host]
        env = {**os.environ, "SIGNALSAFE_MOCK_READY": str(config)}
        if link is not None:
            args.append("--test-call-link-stdin")
        if present_device is not None:
            env["SEREIN_TEST_PRESENT_DEVICE"] = str(present_device)
        if role == "guest":
            env["SEREIN_TEST_WAIT_FOR_VACANCY"] = "1"
        app = subprocess.Popen(args, env=env, stdin=subprocess.PIPE, stdout=log, stderr=log)
        stack.callback(stop, app)
        if link is not None:
            app.stdin.write(link)
        app.stdin.close()
        qr = shared / "ready.json.url"
        wait_for(lambda: qr.exists() or app.poll() is not None, 35)
        if not qr.exists():
            raise RuntimeError("Fixture exited before linking")
        server.stdin.write(json.dumps({"id": 1, "cmd": "provision", "url": qr.read_text()}) + "\n")
        server.stdin.flush()
        reply = read_reply(server)
        if not reply.get("ok"):
            raise RuntimeError("Local account provisioning failed")
        try:
            yield app, config, reply["result"]
        except BaseException:
            messages = [line for line in path.read_text().splitlines() if line.startswith("PEER-QA ")]
            print(role, *messages, sep="\n", file=sys.stderr, flush=True)
            raise
        status = app.wait(255)
        messages = [line for line in path.read_text().splitlines() if line.startswith("PEER-QA ")]
        print(role, *messages, sep="\n", flush=True)
        if status or not messages or messages[-1] != "PEER-QA PASS":
            raise RuntimeError(f"Signed {role} call-link peer fixture failed")


def exercise(host, work):
    container = Path.home() / "Library/Containers" / IDENTIFIER / "Data/tmp"
    if not container.is_dir():
        bootstrap = subprocess.Popen([host],
                                     env={**os.environ, "SIGNALSAFE_MOCK_READY": str(work / "absent")},
                                     stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
        try:
            wait_for(container.is_dir, 15)
        finally:
            stop(bootstrap)
    with account() as first_account, device(host, work, container, first_account, "owner") as (app, config, owner):
        shared = config.with_suffix(".json.guest")
        wait_for(lambda: shared.exists() or app.poll() is not None, 240)
        if not shared.exists():
            raise RuntimeError("Owner did not reach the shared-room test")
        link = shared.read_bytes()
        present_device = int(config.with_suffix(".json.demux").read_text())
        with device(host, work, container, first_account, "second-device", link, present_device) as (_, _, second):
            if second["aci"] != owner["aci"] or second["deviceId"] == owner["deviceId"]:
                raise RuntimeError("Expected a distinct device of the first account")
        with account() as second_account, device(host, work, container, second_account, "guest", link) as (guest_app, gate, guest):
            if guest["aci"] == owner["aci"]:
                raise RuntimeError("Expected a separately registered guest account")
            waiting = gate.with_suffix(".json.waiting")
            wait_for(lambda: waiting.is_file() or guest_app.poll() is not None, 40)
            if not waiting.is_file():
                raise RuntimeError("Guest did not wait outside the occupied room")
            config.with_suffix(".json.done").touch()


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--app", type=Path, default=APP / ".build/Serein.app")
    args = parser.parse_args()
    ports = [int(os.environ.get("SEREIN_TEST_SFU_" + kind + "_PORT", "0")) for kind in ("UDP", "TCP")]
    if not all(0 < port <= 65535 for port in ports) or not os.environ.get("SEREIN_TEST_MOCK_ZK_PARAMS_FILE"):
        parser.error("run via with-calling-frontend.py with a backend and the mock server zk-params")
    with tempfile.TemporaryDirectory(prefix="serein-call-link-peer-") as directory:
        work = Path(directory)
        build_hosts(work)
        host = stage_fixture(args.app.resolve(strict=True), work, *ports)
        exercise(host, work)


if __name__ == "__main__":
    main()
