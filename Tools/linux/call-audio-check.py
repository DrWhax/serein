"""Exercise the production call clock, microphone and speaker using isolated ALSA file devices."""
import os
from pathlib import Path
import struct
import subprocess
import tempfile

ring = Path(__file__).resolve().parents[2] / "Packages/SignalRingRTC"
with tempfile.TemporaryDirectory() as directory:
    root = Path(directory)
    swift = root / "Sources/SwiftCalling"
    tests = root / "Tests/AudioTests"
    swift.mkdir(parents=True)
    tests.mkdir(parents=True)
    (root / "Sources/CLinuxCallAudio").symlink_to(ring / "Sources/CLinuxCallAudio")
    sources = ring / "Sources/SwiftCalling"
    for name in ("CallEchoControl", "MicrophoneProcessing", "SpeakerTimeline", "VoiceAudioHardware",
                 "VoiceCallDevices", "CallSpeaker+Devices"):
        (swift / (name + ".swift")).symlink_to(sources / (name + ".swift"))
    for name in ("CallSpeaker+Linux", "CallMicrophone+Linux", "VoiceAudioRoutes+Linux"):
        (swift / (name + ".swift")).symlink_to(sources / "Linux" / (name + ".swift"))
    for name in ("CallEchoControlTests", "CallSpeakerTests"):
        (tests / (name + ".swift")).symlink_to(ring / "Tests/SignalRingRTCTests" / (name + ".swift"))
    (root / "Package.swift").write_text("""// swift-tools-version:6.2
import PackageDescription
let package = Package(name: "AudioCheck", targets: [
    .target(name: "CLinuxCallAudio", linkerSettings: [.linkedLibrary("asound")]),
    .target(name: "SwiftCalling", dependencies: ["CLinuxCallAudio"], swiftSettings: [
        .strictMemorySafety(), .treatAllWarnings(as: .error), .enableExperimentalFeature("SafeInteropWrappers")
    ]),
    .testTarget(name: "AudioTests", dependencies: ["SwiftCalling"])
])
""")
    (root / "voice.raw").write_bytes(b"".join(struct.pack("<h", i % 400 - 200) for i in range(960)) * 100)
    config = root / "alsa.conf"
    config.write_text(f'''pcm.null {{ type null }}
pcm.checkin {{ type file slave.pcm "null" file "/dev/null" infile "{root}/voice.raw" format "raw" }}
pcm.checkout {{ type file slave.pcm "null" file "{root}/speaker.raw" format "raw" }}
pcm.checkmuted {{ type file slave.pcm "null" file "{root}/muted.raw" format "raw" }}
''')
    subprocess.run(["swift", "test", "--package-path", directory], timeout=120, check=True,
                   env={**os.environ, "SEREIN_ALSA_CHECK": directory, "ALSA_CONFIG_PATH": str(config)})
