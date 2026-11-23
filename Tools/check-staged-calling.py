#!/usr/bin/env python3
"""Verify a staged Serein.app's strict calling service in a local signed XPC host."""
import argparse
import os
from pathlib import Path
import plistlib
import shutil
import subprocess
import sys
import tempfile

ROOT = Path(__file__).resolve().parent.parent
PACKAGE = ROOT / 'Packages' / 'SignalRingRTC'


def run(*args, **options):
    return subprocess.run(args, check=True, **options)


def smoke(bundle):
    bundle = bundle.resolve(strict=True)
    run(sys.executable, ROOT / 'Tools/check-shipping-calling.py', bundle)
    app_info = plistlib.loads((bundle / 'Contents/Info.plist').read_bytes())
    run(bundle / 'Contents/MacOS' / app_info['CFBundleExecutable'], '--check-calling-service', timeout=45)
    source = bundle / 'Contents/XPCServices/SignalCalling.xpc'
    info = plistlib.loads((source / 'Contents/Info.plist').read_bytes())
    peers = app_info['SereinXPCPeers']
    if peers != info['SereinXPCPeers'] or peers['app'] != app_info['CFBundleIdentifier'] or peers['calling'] != info['CFBundleIdentifier']:
        raise ValueError('The signed app and calling service disagree on XPC identities')
    identity = os.environ.get('SIGNALSAFE_SIGN_IDENTITY', '-')
    build = ['swift', 'build', '--package-path', PACKAGE, '-c', 'release']
    run(*build, '--product', 'CallServiceCheck')
    products = Path(run(*build, '--show-bin-path', stdout=subprocess.PIPE, text=True).stdout.strip())
    with tempfile.TemporaryDirectory(prefix='serein-staged-call-') as directory:
        work = Path(directory)
        host = work / 'StagedCallHost.app'
        contents = host / 'Contents'
        (contents / 'MacOS').mkdir(parents=True)
        shutil.copy2(products / 'CallServiceCheck', contents / 'MacOS/StagedCallHost')
        host_info = {'CFBundleIdentifier': peers['app'], 'CFBundleExecutable': 'StagedCallHost', 'CFBundlePackageType': 'APPL',
                     'SereinXPCPeers': peers, 'SereinXPCSameTeam': app_info.get('SereinXPCSameTeam', False)}
        (contents / 'Info.plist').write_bytes(plistlib.dumps(host_info))
        service = contents / 'XPCServices/SignalCalling.xpc'
        shutil.copytree(source, service, symlinks=True)
        entitlements = plistlib.loads(run('codesign', '-d', '--entitlements', ':-', source, stdout=subprocess.PIPE,
                                          stderr=subprocess.DEVNULL).stdout)
        rules = entitlements['com.apple.security.temporary-exception.sbpl']
        local = '(deny network-outbound (remote ip "localhost:*"))'
        if rules.count(local) != 1 or entitlements.get('com.apple.security.app-sandbox') is not True:
            raise ValueError('Unexpected embedded calling sandbox')
        # Both endpoints use 127.0.0.1 for TURN. Replace the production localhost deny on this
        # temporary copy with a grant for local UDP only. Removing the general network-client
        # entitlement leaves App Sandbox denying all other IP destinations.
        rules[rules.index(local)] = '(allow network-outbound (remote udp "localhost:*"))'
        entitlements.pop('com.apple.security.network.client')
        entitlements.pop('com.apple.security.device.audio-input', None)
        entitlements_file = work / 'probe-entitlements.plist'
        entitlements_file.write_bytes(plistlib.dumps(entitlements))
        sign = ['codesign', '--force', '--sign', identity, '--timestamp=none', '--options', 'runtime']
        run(*sign, '--entitlements', entitlements_file, service)
        run(*sign, '-i', peers['app'], host)
        run('codesign', '--verify', '--deep', '--strict', host)
        run(ROOT / 'Tools/with-calling-turn.py', '--timeout', '150', '--transport', 'udp', contents / 'MacOS/StagedCallHost', '--staged-video')


if __name__ == '__main__':
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('app', type=Path, nargs='?', default=ROOT / 'App/SignalSafe/.build/Serein.app')
    smoke(parser.parse_args().app)
