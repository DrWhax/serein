#!/usr/bin/env python3
"""Run decoded-speech interoperability against the pinned RingRTC media engine."""
import argparse
import os
from pathlib import Path
import plistlib
import shutil
import subprocess
import sys
import tempfile
import wave

from calling_reference import PACKAGE, ROOT, TEST_PACKAGE, build_reference, install_peer, peer_entitlements, synthesize


def live_hardware_call(work, relay):
    # As in check-sandbox-profile.sh, use a fresh launchd host and allow same-Mac
    # UDP in this test copy. The installed service retains its local network deny.
    def run(*args, **kwargs):
        return subprocess.run(args, check=True, **kwargs)
    # --live-voice drives the bundled test peer, compiled in only with SEREIN_CALL_TEST_PEER.
    qa = ["-Xswiftc", "-DSEREIN_CALL_TEST_PEER"]
    for product in ["SignalCallingService", "CallServiceCheck"]:
        run("swift", "build", "--package-path", PACKAGE, "-c", "release", "--product", product, *qa)
    products = Path(run("swift", "build", "--package-path", PACKAGE, "-c", "release", *qa,
                        "--show-bin-path", capture_output=True, text=True).stdout.strip())
    app = work / "VoiceCallHost.app"
    service = app / "Contents/XPCServices/SignalCalling.xpc"
    peers = {"app": "org.signalsafe.SignalSafe", "calling": "org.signalsafe.SignalCalling"}
    for bundle, kind, executable, identifier, product in [
        (app, "APPL", "VoiceCallHost", peers["app"], "CallServiceCheck"),
        (service, "XPC!", "SignalCalling", peers["calling"], "SignalCallingService"),
    ]:
        contents = bundle / "Contents"
        (contents / "MacOS").mkdir(parents=True)
        shutil.copy2(products / product, contents / "MacOS" / executable)
        info = dict(CFBundleIdentifier=identifier, CFBundleExecutable=executable, CFBundleName=executable,
                    CFBundleVersion="1", CFBundlePackageType=kind, SereinXPCPeers=peers)
        if kind == "XPC!":
            info["XPCService"] = {"ServiceType": "Application"}
        else:
            info["NSMicrophoneUsageDescription"] = "Test a local Serein voice call using the microphone."
        (contents / "Info.plist").write_bytes(plistlib.dumps(info))
    profile = (ROOT / "Packages/SignalMediaService/Sandbox/SignalCalling.sb").read_text()
    local_deny = '(deny network-outbound (remote ip "localhost:*"))'
    if profile.count(local_deny) != 1:
        raise ValueError("Recheck the local-call QA profile against the production profile")
    test_profile = work / "local-call.sb"
    test_profile.write_text(profile.replace(local_deny, "; Allow the two local QA endpoints to exchange UDP."))
    entitlements = work / "service.plist"
    with entitlements.open("wb") as out:
        run(ROOT / "Tools/sbpl-entitlements.sh", test_profile, stdout=out)
    sign = ["codesign", "--force", "--sign", "-", "--timestamp=none", "--options", "runtime"]
    run(*sign, "--entitlements", entitlements, service)
    # Only the peer carries RingRTC. Its audio device reads bundled speech and
    # discards playout, while the shipping Swift service uses the Mac's devices.
    if relay:
        base_path = ROOT / "Packages/SignalMediaService/Sandbox/SignalCalling.sb"
        base = plistlib.loads(run(ROOT / "Tools/sbpl-entitlements.sh", base_path, capture_output=True).stdout)
        peer_ent = peer_entitlements(base, int(os.environ["SEREIN_TEST_TURN_PORT"]), None)
    else:
        peer_ent = peer_entitlements(plistlib.loads(entitlements.read_bytes()), None, None)
    peer_ent["com.apple.security.cs.disable-library-validation"] = True
    install_peer(app, peer_ent, sign, "Serein voice call test.", 8)
    run(*sign, app)
    run("codesign", "--verify", "--deep", "--strict", app)
    args = ["--relay-port", os.environ["SEREIN_TEST_TURN_PORT"]] if relay else []
    run(app / "Contents/MacOS/VoiceCallHost", "--live-voice", *args, timeout=110)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--relay", action="store_true", help="require the local test TURN server")
    parser.add_argument("--group", action="store_true", help="exercise Signal group and call-link speech on the local SFU with induced loss")
    parser.add_argument("--endpoint", action="store_true", help="drive the complete Swift endpoint through the app's XPC and call APIs")
    parser.add_argument("--live-hardware", action="store_true", help="make a local signed XPC call with the real microphone and speaker")
    parser.add_argument("--dred-weights", type=Path, help="register Signal's pinned Opus model on both endpoints and drop direct audio packets")
    parser.add_argument("--seconds", type=int, default=7, help="duration of each file-backed endpoint call, from 7 to 600 seconds")
    parser.add_argument("--save-audio", type=Path, help="save each peer's decoded PCM as WAV after a passing call")
    parser.add_argument("--build-only", action="store_true", help=argparse.SUPPRESS)
    args = parser.parse_args()
    if args.live_hardware and args.save_audio:
        parser.error("the live hardware test discards microphone playout")
    if args.dred_weights or args.seconds != 7:
        if args.live_hardware:
            parser.error("--dred-weights and --seconds require file-backed calls")
        args.endpoint = True
    if not 7 <= args.seconds <= 600:
        parser.error("--seconds must be between 7 and 600")
    if args.group and (not args.dred_weights or args.live_hardware or args.relay):
        parser.error("--group requires --dred-weights and file-backed calls")
    build_reference()
    if args.build_only:
        return
    if args.relay and "SEREIN_TEST_TURN_PORT" not in os.environ:
        parser.error("--relay requires the local coturn test runner")
    with tempfile.TemporaryDirectory(prefix="serein-speech-") as directory:
        work = Path(directory)
        if args.live_hardware:
            live_hardware_call(work, args.relay)
            return
        synthesize(work, "native", "The blue boat crossed the quiet lake.")
        synthesize(work, "swift", "Seven bright birds flew home before dark.")
        # Each process owns its native device and output file. A stale result from a prior
        # role cannot satisfy the PCM checks on the next call.
        roles = ["group", "call-link"] if args.group else ["caller", "callee"]
        for index, role in enumerate(roles):
            output = work / "native-output.pcm"
            output.unlink(missing_ok=True)
            env = dict(os.environ, SEREIN_SPEECH_DIR=directory, SEREIN_SPEECH_ROLE=role,
                       SEREIN_SPEECH_ROUTE="relay" if args.relay else "direct",
                       SEREIN_KEEP_SPEECH="1" if args.save_audio else "0")
            env["SEREIN_SPEECH_SECONDS"] = str(args.seconds)
            if args.dred_weights:
                env["SEREIN_DRED_WEIGHTS"] = str(args.dred_weights.resolve(strict=True))
            suite = "liveEndpointSpeech" if args.endpoint else "decodedSpeech"
            if args.group:
                env.update(SEREIN_TEST_GROUP_DRED="1", SEREIN_TEST_GROUP_KIND=role)
                suite = "GroupCallInteropTests"
            command = ["swift", "test", "--package-path", TEST_PACKAGE, "-c", "release",
                       "--enable-testable-imports", "--filter", suite]
            if scratch := env.get("SEREIN_SPEECH_SCRATCH"):
                command.extend(["--scratch-path", scratch])
            if index > 0:
                command.append("--skip-build")
            if args.group:
                # The development backend selects Adhoc when admission is enabled.
                admission = ["--require-approval"] if role == "call-link" else []
                command = [sys.executable, ROOT / "Tools/with-calling-sfu.py", *admission, *command]
            result = subprocess.run(command, env=env, stdout=subprocess.PIPE, stderr=subprocess.STDOUT, text=True)
            print(result.stdout, end="")
            if result.returncode or "1 test in 1 suite passed" not in result.stdout or result.stdout.count("speech PCM") != 2:
                raise SystemExit("The mixed-peer speech acceptance test did not pass")
            if args.save_audio:
                dest = args.save_audio / env["SEREIN_SPEECH_ROUTE"] / ("swift-" + role)
                dest.mkdir(parents=True, exist_ok=True)
                for side in ["native", "swift"]:
                    with wave.open(str(dest / (side + "-decoded.wav")), "wb") as audio:
                        audio.setparams((1, 2, 48000, 0, "NONE", "not compressed"))
                        audio.writeframes((work / (side + "-output.pcm")).read_bytes())


if __name__ == "__main__":
    main()
