"""Exercise the production Linux calling engine. Requires coturn, OpenSSL and the Serein toolchain."""
from pathlib import Path
import os
import subprocess
import sys
import tempfile

root = Path(__file__).resolve().parents[2]
ring = root / "Packages/SignalRingRTC"
suites = ["SwiftDirectCallTests", "ICEBindingTests", "ICEHostPairTests", "SRTPTests", "GroupFrameCryptoTests",
          "LinuxCallNetworkTests", "TURNTests", "TURNStreamTests"]
with tempfile.TemporaryDirectory(prefix="serein-call-network-") as tmp:
    package = Path(tmp) / "SignalRingRTC"
    tests = package / "Tests/SignalRingRTCTests"
    tests.mkdir(parents=True)
    (package / "Sources").symlink_to(ring / "Sources")
    (package.parent / "SignalCodecs").symlink_to(root / "Packages/SignalCodecs")
    for suite in suites:
        (tests / (suite + ".swift")).symlink_to(ring / "Tests/SignalRingRTCTests" / (suite + ".swift"))
    # Keep the production engine's manifest settings. The native interop test
    # adapter separately requires the macOS RingRTC reference dylib.
    (package / "Package.swift").write_text((ring / "Package.swift").read_text() + """
let engineTargets = ["SwiftCalling", "CLinuxCallNetwork", "CCallGIO", "CLinuxCallAudio", "CallingWire", "SignalRingRTCTests"]
package.products = []
package.targets.removeAll { !engineTargets.contains($0.name) }
package.dependencies.removeAll { if case .fileSystem = $0.kind { return true }; return false }
package.dependencies.append(.package(path: "../SignalCodecs"))
let tests = package.targets.first { $0.name == "SignalRingRTCTests" }!
tests.dependencies = ["SwiftCalling", .product(name: "Crypto", package: "swift-crypto")]
""")
    build = ["swift", "test", "--build-system", "native", "--package-path", str(package), "-j", "4"]
    if scratch := os.environ.get("SEREIN_CALL_TEST_SCRATCH"):
        build += ["--scratch-path", scratch]
    fixture = [sys.executable, str(root / "Tools/with-calling-turn.py")]
    for transport in ("udp", "tcp", "tls"):
        args = build if transport == "udp" else build + ["--skip-build", "--filter", "TURNTests|TURNStreamTests"]
        subprocess.run(fixture + ["--transport", transport, *args], check=True, timeout=600)
    subprocess.run(fixture + ["--stun-only", *build, "--skip-build", "--filter", "stunUsesTheBoundMediaPort"],
                   check=True, timeout=45)
