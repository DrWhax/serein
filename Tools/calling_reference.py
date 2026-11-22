"""Build the isolated, file-backed RingRTC engine and its signed XPC test peer."""
import array
import os
from pathlib import Path
import plistlib
import shutil
import subprocess
import sys
import tempfile
import wave

ROOT = Path(__file__).resolve().parent.parent
PACKAGE = ROOT / "Packages/SignalRingRTC"
INTEROP = ROOT / "Packages/SignalCallingInterop"
WORK = ROOT / ".build/calling-speech"
REFERENCE = WORK / "vendor/ringrtc"
TEST_PACKAGE = WORK / "Packages/SignalRingRTC"
TEST_INTEROP = WORK / "Packages/SignalCallingInterop"
SERVICE = "SignalCallTestPeer"


def copy_changed(source, destination):
    source, destination = Path(source), Path(destination)
    if not destination.is_file() or source.read_bytes() != destination.read_bytes():
        shutil.copy2(source, destination)
    return destination


def link(source, destination):
    if not destination.is_symlink():
        destination.symlink_to(source.resolve())


def build_reference():
    # Separate package, target directory and dylib keep the file-backed reference
    # out of production builds and allow the ordinary package tests to run concurrently.
    upstream = ROOT / "vendor/ringrtc"
    subprocess.run([ROOT / "Tools/build-ringrtc-ffi.sh", "--prepare-only"], check=True)
    (REFERENCE / "src").mkdir(parents=True, exist_ok=True)
    for name in ["Cargo.toml", "bin", "config", "protobuf", "mrp", "call_sim", "webrtc-sys"]:
        link(upstream / name, REFERENCE / name)
    shutil.copytree(upstream / "src/rust", REFERENCE / "src/rust", dirs_exist_ok=True,
                    ignore=shutil.ignore_patterns("audio_device_module.rs"), copy_function=copy_changed)
    device = REFERENCE / "src/rust/src/webrtc/audio_device_module.rs"
    # ffi/ and sim/ also have a file with this name.
    for source in (upstream / "src/rust").rglob("audio_device_module.rs"):
        target = REFERENCE / source.relative_to(upstream)
        if target != device:
            copy_changed(source, target)
    original = (upstream / device.relative_to(REFERENCE)).read_text()
    start = original.index("let cubeb_worker = Worker::spawn(")
    end = original.index(");", start) + 2
    fixture = ROOT / "Tools/calling-speech/file_device.rs"
    fallback = original[start:end].removeprefix("let cubeb_worker = ").removesuffix(";")
    patched = (original[:start] +
               'let cubeb_worker = if let Some((directory, save_playout)) = speech_fixture() { '
               "spawn_file_device(started_sender, receiver, playout_delay_sender, "
               "input_device_names.clone(), output_device_names.clone(), directory, save_playout) } else { " + fallback + " };" +
               original[end:] + "\n" + fixture.read_text())
    if not device.exists() or device.read_text() != patched:
        device.write_text(patched)

    rust = TEST_PACKAGE / "rust"
    rust.mkdir(parents=True, exist_ok=True)
    for name in ["Cargo.toml", "Cargo.lock", "rust-toolchain"]:
        copy_changed(PACKAGE / "rust" / name, rust / name)
    link(PACKAGE / "rust/src", rust / "src")
    # Keep both manifests in this private tree so the peer's package dependency
    # resolves the file-device library in this Rust target directory.
    if TEST_INTEROP.is_symlink():
        if TEST_INTEROP.resolve() != INTEROP.resolve():
            raise ValueError(f"Unexpected interop fixture symlink: {TEST_INTEROP}")
        TEST_INTEROP.unlink()
    TEST_INTEROP.mkdir(exist_ok=True)
    for source, target in [(PACKAGE, TEST_PACKAGE), (INTEROP, TEST_INTEROP)]:
        link(source / "Sources", target / "Sources")
        copy_changed(source / "Package.swift", target / "Package.swift")
    link(PACKAGE / "Tests", TEST_PACKAGE / "Tests")
    for package in (ROOT / "Packages").iterdir():
        if package.is_dir() and package not in (PACKAGE, INTEROP):
            link(package, WORK / "Packages" / package.name)
    subprocess.run(["cargo", "build", "--locked", "--release", "--target", "aarch64-apple-darwin",
                    "--target-dir", rust / "target"],
                   cwd=rust, env=dict(os.environ, OUTPUT_DIR=str(upstream / "out")), check=True)


def synthesize(work, side, phrase):
    source = work / (side + ".aiff")
    wav = work / (side + ".wav")
    subprocess.run(["say", "-r", "165", "-o", source, phrase], check=True)
    subprocess.run(["afconvert", "-f", "WAVE", "-d", "LEI16@48000", "-c", "1", source, wav], check=True)
    with wave.open(str(wav)) as stream:
        assert (stream.getframerate(), stream.getsampwidth(), stream.getnchannels()) == (48000, 2, 1)
        raw = stream.readframes(stream.getnframes())
    samples = array.array("h", raw)
    if sys.byteorder != "little":
        samples.byteswap()
    if len(samples) > 480_000 or sum(abs(x) > 500 for x in samples) < 4_800:
        raise ValueError("Speech synthesis produced an empty or unreasonably long fixture")
    (work / (side + "-input.pcm")).write_bytes(raw)


def run(*args, **options):
    return subprocess.run(args, check=True, **options)


def peer_entitlements(base, udp_port, tcp_port):
    # Inherit the calling service's file, process and device restrictions. The generated
    # microphone and silent output run entirely in the native audio-device worker.
    entitlements = dict(base)
    entitlements.pop("com.apple.security.device.audio-input", None)
    entitlements.pop("com.apple.security.device.camera", None)
    rules = [rule.replace(r"/SignalCalling\.xpc", r"/SignalCallTestPeer\.xpc")
             for rule in base["com.apple.security.temporary-exception.sbpl"]]
    audio = next(rule for rule in rules if rule.startswith("(deny mach-lookup (require-all") and "audiohald" in rule)
    rules[rules.index(audio)] = ('(deny mach-lookup (require-all (global-name-regex #".*") '
                                 '(require-not (global-name "com.apple.dnssd.service")) '
                                 '(require-not (global-name "com.apple.trustd.agent"))))')
    rules.append("(deny device-microphone)")
    if udp_port is not None or tcp_port is not None:
        entitlements.pop("com.apple.security.network.client", None)
        # This fixture can reach only its loopback SFU's assigned ports. Start from a
        # production profile even if the GUI's separate strict service is already staged.
        rules.remove('(deny network-outbound (remote ip "localhost:*"))')
        for transport, port in [("udp", udp_port), ("tcp", tcp_port)]:
            if port is not None:
                if not 1 <= port <= 65535:
                    raise ValueError("Invalid loopback SFU port")
                rules.append(f'(allow network-outbound (remote {transport} "localhost:{port}"))')
    entitlements["com.apple.security.temporary-exception.sbpl"] = rules
    return entitlements


def install_peer(app, peer_ent, sign, phrase_text, attenuation):
    """Build against the private file-device library and sign it inside this QA peer."""
    contents = app / "Contents"
    info = plistlib.loads((contents / "Info.plist").read_bytes())
    identifier = info["CFBundleIdentifier"] + ".call-test-peer"
    services = contents / "XPCServices"
    final = services / (SERVICE + ".xpc")
    source = services / "SignalCalling.xpc"
    build = ["swift", "build", "--package-path", TEST_INTEROP, "-c", "release"]
    run(*build, "--product", "SignalCallTestPeerService")
    products = Path(run(*build, "--show-bin-path", capture_output=True, text=True).stdout.strip())
    with tempfile.TemporaryDirectory(prefix="serein-test-peer-") as directory:
        work = Path(directory)
        service = work / final.name
        peer = service / "Contents"
        media = peer / "Resources/ReferenceSpeech"
        media.mkdir(parents=True)
        synthesize(media, "native", phrase_text)
        # Give the listener time between announcements and keep the sound level comfortable.
        phrase = media / "native-input.pcm"
        samples = array.array("h", phrase.read_bytes())
        phrase.write_bytes(array.array("h", (x // attenuation for x in samples)).tobytes() + bytes(2 * 48_000 * 2))
        if phrase.stat().st_size > 10 * 48_000 * 2:
            raise ValueError("The reference audio exceeds the native fixture's ten-second loop")
        for extension in ("aiff", "wav"):
            (media / f"native.{extension}").unlink()

        (peer / "MacOS").mkdir()
        binary = peer / "MacOS" / SERVICE
        shutil.copy2(products / "SignalCallTestPeerService", binary)
        release = Path("rust/target/aarch64-apple-darwin/release")
        (peer / "Frameworks").mkdir()
        library = peer / "Frameworks/libsignal_ringrtc.dylib"
        shutil.copy2(TEST_PACKAGE / release / library.name, library)
        # Cargo puts the build directory in the dylib's install name. Resolve it to the
        # signed copy beside this test executable even when the checkout is still present.
        bundled_name = "@loader_path/../Frameworks/" + library.name
        dependencies = run("otool", "-L", binary, capture_output=True, text=True).stdout.splitlines()[1:]
        names = [line.strip().split(" (compatibility version", 1)[0] for line in dependencies]
        reference, = [name for name in names if Path(name).name == library.name]
        run("install_name_tool", "-change", reference, bundled_name, "-delete_rpath", TEST_PACKAGE / release, binary)
        run("install_name_tool", "-id", "@rpath/" + library.name, library)
        service_info = plistlib.loads((source / "Contents/Info.plist").read_bytes())
        service_info.update(CFBundleIdentifier=identifier, CFBundleExecutable=SERVICE, CFBundleName=SERVICE,
                            SereinXPCPeers=info["SereinXPCPeers"])
        (peer / "Info.plist").write_bytes(plistlib.dumps(service_info))
        peer_plist = work / "peer.entitlements"
        peer_plist.write_bytes(plistlib.dumps(peer_ent))
        run(*sign, library)
        run(*sign, "--entitlements", peer_plist, service)
        run("codesign", "--verify", "--deep", "--strict", service)
        if final.exists():
            # Replace only a previously staged copy bearing this app's expected identifier.
            previous = plistlib.loads((final / "Contents/Info.plist").read_bytes())
            if previous.get("CFBundleIdentifier") != identifier:
                raise ValueError("Another service occupies the test peer path")
            shutil.rmtree(final)
        shutil.copytree(service, final, symlinks=True)
