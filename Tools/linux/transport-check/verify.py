"""Run with the path to the Linux TransportCheck executable."""
import math
import os
import signal
import socket
import struct
import sys
import tempfile
from pathlib import Path

binary = os.path.abspath(sys.argv[1])


def route():
    return socket.socketpair(socket.AF_UNIX, socket.SOCK_SEQPACKET)


def launch(mode, routes, environment=None):
    actions = [(os.POSIX_SPAWN_DUP2, endpoint.fileno(), slot) for slot, endpoint in routes.items()]
    return os.posix_spawn(binary, [binary, mode], environment if environment is not None else os.environ, file_actions=actions)


app_decoder, decoder = route()
app_parser, parser = route()
app_fetcher, fetcher = route()
fetcher_parser, delegated_parser = route()
app_voice, voice = route()
fixture = tempfile.TemporaryDirectory()
pcm = Path(fixture.name, "input.raw")
configuration = Path(fixture.name, "alsa.conf")
# No host microphone is accessed. The file plugin supplies mono float samples.
period = b"".join(struct.pack("<f", 0.4 * math.sin(2 * math.pi * frame / 48)) for frame in range(48))
pcm.write_bytes(period * 8000)
configuration.write_text(
    'pcm.null { type null }\n'
    'pcm.!default { type file slave.pcm "null" file "/dev/null" format "raw" '
    f'infile "{pcm}" }}\n'
)
services = []
try:
    services.append(launch("service", {160: decoder}))
    services.append(launch("parser", {161: parser, 167: delegated_parser}))
    services.append(launch("fetcher", {162: fetcher, 167: fetcher_parser}))
    services.append(launch("voice", {164: voice}, {**os.environ, "ALSA_CONFIG_PATH": str(configuration)}))
    client = launch("client", {160: app_decoder, 161: app_parser, 162: app_fetcher, 164: app_voice})
    for endpoint in (app_decoder, decoder, app_parser, parser, app_fetcher, fetcher, fetcher_parser, delegated_parser, app_voice, voice):
        endpoint.close()
    _, status = os.waitpid(client, 0)
    sys.exit(os.waitstatus_to_exitcode(status))
finally:
    for pid in services:
        try:
            os.kill(pid, signal.SIGTERM)
        except ProcessLookupError:
            pass
        os.waitpid(pid, 0)
    fixture.cleanup()
