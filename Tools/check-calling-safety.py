#!/usr/bin/env python3
"""Verify the strict Swift calling build and its ban on explicit safety escapes."""
from pathlib import Path
import json
import shlex
import subprocess
import tempfile


ROOT = Path(__file__).resolve().parent.parent
PACKAGE = ROOT / "Packages/SignalRingRTC"
INTEROP = ROOT / "Packages/SignalCallingInterop"
STRICT = ["-swift-version", "6", "-strict-memory-safety", "-warnings-as-errors"]


def run(args, **kwargs):
    return subprocess.run(args, check=True, text=True, **kwargs)


def expect_failure(args, diagnostic):
    result = subprocess.run(args, text=True, stdout=subprocess.PIPE, stderr=subprocess.STDOUT)
    if result.returncode == 0 or diagnostic not in result.stdout:
        raise SystemExit(f"Expected {diagnostic!r} from {args}:\n{result.stdout}")


def check_rewrite_dependencies():
    # Keep the verified Swift source closure in sync with the actual SwiftPM graph.
    # A dependency added to the voice backend must also enter the safety checks.
    codecs = ROOT / "Packages/SignalCodecs"
    for package, name, dependencies, products in [
        (PACKAGE, "SignalCallingService", ["CallService", "CallXPC", "SwiftCallingServiceAdapter"], ["MediaXPCInterface"]),
        (PACKAGE, "CallService", ["CallXPC", "SignalRingRTC"], ["MediaXPCInterface"]),
        (PACKAGE, "CallXPC", ["SignalRingRTC"], ["MediaXPCInterface"]),
        (ROOT / "Packages/SignalMediaService", "MediaXPCInterface", [], []),
        (PACKAGE, "SwiftCallingServiceAdapter", ["SignalRingRTC", "SwiftCalling"], []),
        (PACKAGE, "CallingWire", [], []),
        (PACKAGE, "SignalRingRTC", ["CallingWire"], []),
        (PACKAGE, "SwiftCalling", ["CallingWire"], ["CodecCore", "VideoVP8", "VideoVP9"]),
        (codecs, "VideoVP9", [], []),
        (codecs, "VideoVP8", ["CodecCore"], []),
        (codecs, "CodecCore", [], []),
    ]:
        description = json.loads(run(["swift", "package", "--package-path", package, "describe",
                                      "--type", "json"], capture_output=True).stdout)
        target = next(t for t in description["targets"] if t["name"] == name)
        if (target["module_type"] != "SwiftTarget" or target["path"] != "Sources/" + name
                or set(target.get("target_dependencies", [])) != set(dependencies)
                or target.get("product_dependencies", []) != products):
            raise SystemExit(f"Update the checked source closure for {name} and its dependencies")
        if name == "SwiftCalling":
            if not any(d.get("path") == str(codecs) for d in description["dependencies"]):
                raise SystemExit("The checked CodecCore must come from the local SignalCodecs package")
        elif package == codecs and not any(p["name"] == name and p["targets"] == [name] for p in description["products"]):
            raise SystemExit(f"The {name} product must contain the checked {name} target")


def check_compiler_and_sources(tmp):
    swiftc = Path(run(["xcrun", "-f", "swiftc"], capture_output=True).stdout.strip())
    host = swiftc.parent.parent / "lib/swift/host"
    compiler = [swiftc, *STRICT, "-module-cache-path", tmp / "modules"]
    checker = tmp / "check-sources"
    run([*compiler, "-I", host, "-L", host, "-Xlinker", "-rpath", "-Xlinker", host,
         ROOT / "Tools/calling-safety/CheckSources.swift", "-o", checker])
    sources = sorted((PACKAGE / "Sources").rglob("*.swift")) + sorted((PACKAGE / "Tests").rglob("*.swift"))
    sources += sorted((INTEROP / "Sources").rglob("*.swift"))
    for codec in ["CodecCore", "VideoVP8", "VideoVP9"]:
        sources += sorted((ROOT / "Packages/SignalCodecs/Sources" / codec).rglob("*.swift"))
    sources += [ROOT / "Tools/calling-safety/ProbePlayout.swift"]
    run([checker, *sources])

    probe = tmp / "Probe.swift"
    typecheck = [*compiler, "-typecheck", probe]
    probe.write_text("func first(_ bytes: [UInt8]) -> UInt8? { bytes.first }")
    run(typecheck)
    probe.write_text('#warning("calling-warning-probe")')
    expect_failure(typecheck, "error: calling-warning-probe")
    cast = "func cast<T,U>(_ t: T, to: U.Type) -> U { unsafeBitCast(t, to: U.self) }"
    probe.write_text(cast)
    expect_failure(typecheck, "[#StrictMemorySafety]")
    probe.write_text(cast.replace("{ unsafeBitCast", "{ unsafe unsafeBitCast"))
    run(typecheck)
    expect_failure([checker, probe], "calling safety policy rejects 'unsafe'")
    return checker


def check_build(tmp, config, checker):
    # Build the production products. Compiling the interop test targets checks their
    # flags and source lists without needing to link the native reference library.
    log = tmp / f"{config}.log"
    build = ["--build-system", "native", "-c", config, "-v"]
    with log.open("w") as output:
        for command in [
            ["swift", "build", "--package-path", PACKAGE, "--scratch-path", tmp / "build", *build],
            ["swift", "build", "--package-path", PACKAGE, "--scratch-path", tmp / "build", *build,
             "--target", "SignalRingRTCTests", "-Xswiftc", "-enable-testing"],
            ["swift", "build", "--package-path", INTEROP, "--scratch-path", tmp / "interop", *build, "--target", "SignalCallTestPeerService"],
        ]:
            result = subprocess.run(command, stdout=output, stderr=subprocess.STDOUT)
            if result.returncode:
                break
    lines = log.read_text().splitlines()
    if result.returncode:
        diagnostics = [line for line in lines if "error:" in line]
        raise SystemExit("\n".join(diagnostics[-20:] or lines[-10:]))
    targets = {p.name for base in [PACKAGE / "Sources", PACKAGE / "Tests", INTEROP / "Sources"] for p in base.iterdir()
               if p.is_dir() and any(p.rglob("*.swift"))}
    targets.update(["CodecCore", "VideoVP8", "VideoVP9"])
    seen = set()
    for line in lines:
        if "swiftc " not in line or " -module-name " not in line:
            continue
        args = shlex.split(line)
        if Path(args[0]).name != "swiftc" or "-emit-module" not in args:
            continue
        name = args[args.index("-module-name") + 1]
        if name in targets:
            if not (set(STRICT) <= set(args)) or args[args.index("-swift-version") + 1] != "6" or any(
                opt in args for opt in ["-suppress-warnings", "-no-warnings-as-errors", "-Ounchecked"]
            ):
                raise SystemExit(f"{config} build of {name} has incorrect compiler settings")
            if name in {"SwiftCallingServiceAdapter", "CallingWire", "SignalRingRTC", "SwiftCalling", "CodecCore", "VideoVP8", "VideoVP9"}:
                source_lists = [Path(arg[1:]) for arg in args if arg.startswith("@") and Path(arg[1:]).name == "sources"]
                if not source_lists:
                    raise SystemExit(f"{config} {name} compiler invocation has no SwiftPM source list")
                for listing in source_lists:
                    run([checker, *shlex.split(listing.read_text())])
            seen.add(name)
    if seen != targets:
        raise SystemExit(f"{config} missing Swift compiler invocations for {sorted(targets - seen)}")
    print(f"{config}: verified compiler invocations for {len(seen)} calling targets")


if __name__ == "__main__":
    with tempfile.TemporaryDirectory(prefix="serein-calling-safety-") as directory:
        scratch = Path(directory)
        check_rewrite_dependencies()
        checker = check_compiler_and_sources(scratch)
        for configuration in ["debug", "release"]:
            check_build(scratch, configuration, checker)
    print("calling safety: ok")
