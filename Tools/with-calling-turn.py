#!/usr/bin/env python3
"""Run a command against a private, loopback-only coturn instance. Requires turnserver in PATH or SEREIN_TURNSERVER."""
import os
from pathlib import Path
import secrets
import shutil
import socket
import ssl
import struct
import subprocess
import sys
import tempfile
import time


from calling_fixture import free_port, make_test_certificates


def run(command, transport, stun_only=False, command_timeout=None):
    executable = shutil.which(os.getenv('SEREIN_TURNSERVER', 'turnserver'))
    if not executable:
        raise SystemExit('Install coturn or set SEREIN_TURNSERVER to its turnserver executable.')
    port = free_port(socket.SOCK_STREAM if transport == 'tcp' else socket.SOCK_DGRAM)
    with tempfile.TemporaryDirectory(prefix='serein-turn-') as tmp:
        work = Path(tmp)
        log = work / 'turn.log'
        # Model a TURN server behind one-to-one NAT. RingRTC requires globally unique
        # relay candidates. Coturn translates the TEST-NET address in both directions
        # when encoding/decoding TURN attributes. Its actual sockets all use loopback.
        args = [executable, '-n', '--listening-ip=127.0.0.1', '--relay-ip=127.0.0.1',
                f'--listening-port={port}', '--no-dtls', '--no-tcp-relay',
                '--no-cli', '--allow-loopback-peers', '--no-multicast-peers',
                '--denied-peer-ip=0.0.0.0-255.255.255.255', '--allowed-peer-ip=127.0.0.1',
                '--denied-peer-ip=::-ffff:ffff:ffff:ffff:ffff:ffff:ffff:ffff', '--relay-threads=1',
                '--lt-cred-mech', '--fingerprint', '--realm=serein.test', '--user=serein:serein-test-relay',
                '--user-quota=16', '--total-quota=16', '--no-auth-pings', f'--userdb={work / "users"}',
                f'--pidfile={work / "pid"}', '--log-file=stdout', '--simple-log', '-v']
        env = dict(os.environ, SEREIN_TEST_TURN_PORT=str(port))
        if stun_only:
            # Binding responses must report the listener's actual routable loopback address.
            args.append('--stun-only')
            env['SEREIN_TEST_STUN_ONLY'] = '1'
        else:
            args.append('--external-ip=192.0.2.1/127.0.0.1')
        if transport == 'tls':
            make_test_certificates(work)
            tls_port = free_port(socket.SOCK_STREAM)
            while tls_port == port:
                tls_port = free_port(socket.SOCK_STREAM)
            args.extend([f'--tls-listening-port={tls_port}', f'--cert={work / "server.pem"}',
                         f'--pkey={work / "server.key"}'])
            env['SEREIN_TEST_TURN_TLS_PORT'] = str(tls_port)
            env['SEREIN_TEST_TURN_CA'] = str(work / 'root.der')
        else:
            args.append('--no-tls')
        if transport == 'tcp':
            args.append('--no-udp')
        elif transport == 'udp':
            args.append('--no-tcp')
        # RingRTC's TLS uses its bundled trust anchors. The TLS suite uses UDP for the
        # stock peer and the separately authenticated TLS listener for the Swift peer.
        peer_transport = 'udp' if transport == 'tls' else transport
        env['SEREIN_TEST_TURN_URI'] = f'turn:127.0.0.1:{port}?transport={peer_transport}'
        if os.environ.get('SEREIN_TEST_TURN_SHORT_LEASE') == '1':
            args.extend(['--max-allocate-lifetime=8', '--stale-nonce=2'])
        with log.open('w') as output:
            server = subprocess.Popen(args, stdout=output, stderr=subprocess.STDOUT, cwd=work)
        try:
            txid = secrets.token_bytes(12)
            binding = struct.pack('!HHI', 1, 0, 0x2112a442) + txid
            deadline = time.monotonic() + 10
            while time.monotonic() < deadline and server.poll() is None:
                kind = socket.SOCK_DGRAM if transport == 'udp' else socket.SOCK_STREAM
                try:
                    with socket.socket(socket.AF_INET, kind) as probe:
                        probe.settimeout(0.5)
                        probe.connect(('127.0.0.1', tls_port if transport == 'tls' else port))
                        if transport == 'tls':
                            context = ssl.create_default_context(cafile=str(work / 'root.pem'))
                            with context.wrap_socket(probe, server_hostname='localhost') as secure:
                                secure.sendall(binding)
                                result = secure.recv(2048)
                        else:
                            probe.sendall(binding)
                            result = probe.recv(2048)
                    if result[:2] == b'\x01\x01' and result[8:20] == txid:
                        break
                except (socket.timeout, ConnectionRefusedError):
                    time.sleep(0.05)
            else:
                raise RuntimeError('coturn did not answer its local STUN readiness probe')
            result = subprocess.run(command, env=env, timeout=command_timeout)
            if result.returncode:
                print('\n'.join(log.read_text().splitlines()[-40:]), file=sys.stderr)
            return result.returncode
        except Exception:
            print(log.read_text(), file=sys.stderr)
            raise
        finally:
            server.terminate()
            try:
                server.wait(timeout=4)
            except subprocess.TimeoutExpired:
                server.kill()
                server.wait()


if __name__ == '__main__':
    args = sys.argv[1:]
    command_timeout = None
    if len(args) >= 2 and args[0] == '--timeout':
        command_timeout, args = int(args[1]), args[2:]
        if command_timeout <= 0:
            raise SystemExit('--timeout must be a positive number of seconds')
    transport = 'udp'
    stun_only = args[:1] == ['--stun-only']
    if stun_only:
        args = args[1:]
    elif len(args) >= 2 and args[0] == '--transport':
        transport, args = args[1], args[2:]
    if not args or transport not in ('udp', 'tcp', 'tls'):
        raise SystemExit('usage: with-calling-turn.py [--timeout seconds] [--stun-only | --transport udp|tcp|tls] command [args ...]')
    sys.exit(run(args, transport, stun_only, command_timeout))
