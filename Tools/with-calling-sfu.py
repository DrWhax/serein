#!/usr/bin/env python3
"""Run a command against the real Signal Calling Service test HTTP API and loopback SFU."""
import argparse
import asyncio
import contextlib
import os
from pathlib import Path
import shutil
import socket
import ssl
import sys
import tempfile

from calling_fixture import free_port, make_test_certificates

LOCAL = '127.0.0.1'


async def bridge_client(reader, writer, udp_port):
    """The upstream non-Linux packet server is UDP-only. Use one UDP peer per RFC 4571 stream."""
    loop = asyncio.get_running_loop()
    with socket.socket(socket.AF_INET, socket.SOCK_DGRAM) as uplink:
        uplink.bind((LOCAL, 0))
        uplink.connect((LOCAL, udp_port))
        uplink.setblocking(False)

        async def to_sfu():
            while True:
                size = int.from_bytes(await reader.readexactly(2), 'big')
                if size:
                    await loop.sock_sendall(uplink, await reader.readexactly(size))

        async def to_client():
            while True:
                data = await loop.sock_recv(uplink, 65535)
                writer.write(len(data).to_bytes(2, 'big') + data)
                await writer.drain()

        tasks = [asyncio.create_task(to_sfu()), asyncio.create_task(to_client())]
        try:
            await asyncio.wait(tasks, return_when=asyncio.FIRST_COMPLETED)
        finally:
            for task in tasks:
                task.cancel()
            await asyncio.gather(*tasks, return_exceptions=True)
            writer.close()
            with contextlib.suppress(OSError):
                await writer.wait_closed()


async def run(command, mode, require_approval, endorsements, work):
    variable = 'SEREIN_TEST_SFU_ENDORSEMENT_BINARY' if endorsements else 'SEREIN_TEST_SFU_BINARY'
    executable = shutil.which(os.environ.get(variable, '' if endorsements else 'calling_backend'))
    if not executable:
        raise SystemExit(f'Set {variable} to the local calling_backend executable described in QA.md.')
    executable = str(Path(executable).resolve())
    udp = free_port(socket.SOCK_DGRAM)
    ports = set()

    def tcp_port():
        while True:
            number = free_port(socket.SOCK_STREAM)
            if number not in ports:
                ports.add(number)
                return number

    http, tcp, tls = tcp_port(), tcp_port(), tcp_port()
    args = [executable, '--binding-ip', LOCAL, '--ice-candidate-ip', LOCAL,
            '--ice-candidate-port', str(udp), '--ice-candidate-port-tcp', str(tcp), '--signaling-port', str(http)]
    env = dict(os.environ, SEREIN_TEST_SFU_URL=f'http://{LOCAL}:{http}', SEREIN_TEST_SFU_TRANSPORT=mode,
               SEREIN_TEST_SFU_TCP='1' if mode == 'tcp' else '0')
    if require_approval:
        args.append("--new-clients-require-approval")
        env["SEREIN_TEST_SFU_APPROVAL"] = "1"
    if endorsements:
        # zkgroup::ServerSecretParams::generate([71; 32]).get_endorsement_root_key_pair().
        # The child verifies the backend's actual issuance using the same local test seed.
        args.extend(["--endorsement-secret", "ADbupDqGTuYJMNN249S/nygSoStJDEeoLO0A7mvXwxID"])
        env["SEREIN_TEST_SFU_ENDORSEMENTS"] = str(work / "admission-endorsements.json")
    context = None
    if mode == 'tls':
        make_test_certificates(work)
        args += ['--ice-candidate-port-tls', str(tls), '--hostname', 'localhost',
                 '--certificate-file-path', str(work / 'server.pem'), '--key-file-path', str(work / 'server.key')]
        env['SEREIN_TEST_SFU_CA'] = str(work / 'root.der')
        context = ssl.SSLContext(ssl.PROTOCOL_TLS_SERVER)
        context.minimum_version = ssl.TLSVersion.TLSv1_3 if ssl.HAS_TLSv1_3 else ssl.TLSVersion.TLSv1_2
        context.load_cert_chain(work / 'server.pem', work / 'server.key')

    bridge = None
    if sys.platform != 'linux' and mode in ('tcp', 'tls'):
        bridge = await asyncio.start_server(lambda r, w: bridge_client(r, w, udp), LOCAL,
                                            tls if mode == 'tls' else tcp, ssl=context, limit=65536)
        print(f'SFU {mode.upper()} test uses a loopback RFC 4571 bridge to the upstream UDP packet server.', flush=True)
    log = work / 'sfu.log'
    with log.open('wb') as output:
        server = await asyncio.create_subprocess_exec(*args, stdout=output, stderr=output, cwd=work)
    try:
        for _ in range(200):
            if server.returncode is not None:
                break
            try:
                reader, writer = await asyncio.open_connection(LOCAL, http)
                writer.write(b'GET /metrics HTTP/1.1\r\nHost: localhost\r\nConnection: close\r\n\r\n')
                await writer.drain()
                status = await asyncio.wait_for(reader.readline(), timeout=2)
                writer.close()
                await writer.wait_closed()
                if status.startswith(b'HTTP/1.1 200'):
                    break
            except (ConnectionError, asyncio.TimeoutError):
                pass
            await asyncio.sleep(0.05)
        else:
            raise RuntimeError('SFU did not answer the local readiness probe')
        if server.returncode is not None:
            raise RuntimeError('SFU exited before its local readiness probe')
        child = await asyncio.create_subprocess_exec(*command, env=env)
        try:
            status = await child.wait()
        finally:
            if child.returncode is None:
                child.terminate()
                await child.wait()
        if status:
            print('\n'.join(log.read_text(errors='replace').splitlines()[-25:]), file=sys.stderr)
        return status
    except Exception:
        print(log.read_text(errors='replace')[-8000:], file=sys.stderr)
        raise
    finally:
        if bridge:
            bridge.close()
            await bridge.wait_closed()
        if server.returncode is None:
            server.terminate()
            try:
                await asyncio.wait_for(server.wait(), timeout=3)
            except asyncio.TimeoutError:
                server.kill()
                await server.wait()


if __name__ == '__main__':
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--endorsements', action='store_true', help='exercise the upstream fragment-delivery fixture from QA.md')
    parser.add_argument('--require-approval', action='store_true', help='exercise SFU admission for new clients')
    parser.add_argument('--transport', choices=['udp', 'tcp', 'tls'], default='udp')
    parser.add_argument('command', nargs=argparse.REMAINDER)
    args = parser.parse_args()
    if not args.command:
        parser.error('supply the command to run against the local SFU')
    with tempfile.TemporaryDirectory(prefix='serein-sfu-') as tmp:
        sys.exit(asyncio.run(run(args.command, args.transport, args.require_approval or args.endorsements, args.endorsements, Path(tmp))))
