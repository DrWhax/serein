"""Run with the paths to TransportCheck, SignalMediaDecoderService and SignalLinkPreviewParserService."""
import os
import pathlib
import signal
import socket
import struct
import sys
import tempfile
import zlib

def chunk(kind, data):
    return struct.pack(">I", len(data)) + kind + data + struct.pack(">I", zlib.crc32(kind + data))

def start(binary, arguments, routes, *, fileless=False):
    actions = [(os.POSIX_SPAWN_DUP2, endpoint.fileno(), slot) for slot, endpoint in routes.items()]
    environment = os.environ.copy()
    if fileless:
        environment["LD_LIBRARY_PATH"] = "/usr/local/lib/serein/workers"
    return os.posix_spawn(binary, [binary, *arguments], environment, file_actions=actions)

client, decoder, parser = map(os.path.abspath, sys.argv[1:])
edges = [socket.socketpair(socket.AF_UNIX, socket.SOCK_SEQPACKET) for _ in range(4)]
(a_dec, dec), (a_parse, parse), (a_fetch, fetch), (delegate, delegated) = edges
services = []
with tempfile.TemporaryDirectory() as work:
    image = pathlib.Path(work, "test.png")
    header = struct.pack(">IIBBBBB", 3, 2, 8, 2, 0, 0, 0)
    image.write_bytes(b"\x89PNG\r\n\x1a\n" + chunk(b"IHDR", header) +
                      chunk(b"IDAT", zlib.compress((b"\0" + b"\x20\x40\x80"*3)*2)) + chunk(b"IEND", b""))
    try:
        services.append(start(decoder, [], {160: dec}, fileless=True))
        services.append(start(parser, [], {161: parse, 167: delegated}, fileless=True))
        services.append(start(client, ["fetcher"], {162: fetch, 167: delegate}))
        app = start(client, ["confined", str(image)], {160: a_dec, 161: a_parse, 162: a_fetch})
        for pair in edges:
            for endpoint in pair:
                endpoint.close()
        _, status = os.waitpid(app, 0)
        if status:
            for name, pid in zip(["decoder", "parser", "fetcher"], services.copy()):
                ended, child_status = os.waitpid(pid, os.WNOHANG)
                if ended:
                    services.remove(ended)
                    print(f"{name} exited with {os.waitstatus_to_exitcode(child_status)}", file=sys.stderr)
        sys.exit(os.waitstatus_to_exitcode(status))
    finally:
        for pid in services:
            try:
                os.kill(pid, signal.SIGTERM)
            except ProcessLookupError:
                pass
            os.waitpid(pid, 0)
