#!/bin/sh
# Actual launchd XPC services under the production parser profiles: startup must work,
# then allocation above a low test threshold must break the connection (not time out).
set -eu
root=$(cd "$(dirname "$0")/.." && pwd)
work=$(mktemp -d /tmp/signalsafe-memory.XXXXXX)
trap 'rm -rf "$work"' EXIT
iface="$root/Packages/SignalMediaService/Sources/MediaXPCInterface"
swiftc -swift-version 6 -strict-memory-safety -warnings-as-errors -module-name MemoryProbe "$iface"/*.swift "$root/Tools/memory-probe/service/main.swift" -o "$work/service"
swiftc -swift-version 6 -strict-memory-safety -warnings-as-errors -module-name MemoryHost "$iface"/*.swift "$root/Tools/memory-probe/host/main.swift" -o "$work/host"
python3 - "$root" "$work" <<'PY'
import pathlib, plistlib, subprocess, sys
root, work = map(pathlib.Path, sys.argv[1:])
host = work / 'MemoryHost.app'
(host / 'Contents/MacOS').mkdir(parents=True)
(host / 'Contents/MacOS/MemoryHost').write_bytes((work / 'host').read_bytes())
(host / 'Contents/MacOS/MemoryHost').chmod(0o755)
def plist(path, value): path.write_bytes(plistlib.dumps(value))
plist(host / 'Contents/Info.plist', dict(CFBundleIdentifier='org.signalsafe.SignalSafe', CFBundleExecutable='MemoryHost', CFBundlePackageType='APPL'))
for name in ['SignalMediaDecoder', 'SignalMessageParser', 'SignalLinkPreviewParser']:
    bundle = host / f'Contents/XPCServices/{name}.xpc'
    (bundle / 'Contents/MacOS').mkdir(parents=True)
    exe = bundle / f'Contents/MacOS/{name}'
    exe.write_bytes((work / 'service').read_bytes()); exe.chmod(0o755)
    plist(bundle / 'Contents/Info.plist', dict(CFBundleIdentifier=f'org.signalsafe.memory.{name}', CFBundleExecutable=name, CFBundlePackageType='XPC!', XPCService=dict(ServiceType='Application')))
    ent = work / f'{name}.plist'
    with ent.open('w') as out:
        subprocess.run(['sh', str(root / 'Tools/sbpl-entitlements.sh'), str(root / f'Packages/SignalMediaService/Sandbox/{name}.sb')], stdout=out, check=True)
    subprocess.run(['codesign', '--force', '--sign', '-', '--timestamp=none', '--options', 'runtime', '--entitlements', str(ent), str(bundle)], check=True)
subprocess.run(['codesign', '--force', '--sign', '-', '--timestamp=none', '-i', 'org.signalsafe.SignalSafe', str(host)], check=True)
subprocess.run(['/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister', '-f', str(host)], check=True)
subprocess.run([str(host / 'Contents/MacOS/MemoryHost')] + [f'org.signalsafe.memory.{n}' for n in ['SignalMediaDecoder', 'SignalMessageParser', 'SignalLinkPreviewParser']], check=True, timeout=45)
PY
