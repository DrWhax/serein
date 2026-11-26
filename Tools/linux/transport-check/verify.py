"""Run with the path to the Linux TransportCheck executable."""
import os
import signal
import socket
import sys

binary = os.path.abspath(sys.argv[1])


def route():
    return socket.socketpair(socket.AF_UNIX, socket.SOCK_SEQPACKET)


def launch(mode, routes):
    actions = [(os.POSIX_SPAWN_DUP2, endpoint.fileno(), slot) for slot, endpoint in routes.items()]
    return os.posix_spawn(binary, [binary, mode], os.environ, file_actions=actions)


app_decoder, decoder = route()
app_parser, parser = route()
app_fetcher, fetcher = route()
fetcher_parser, delegated_parser = route()
services = []
try:
    services.append(launch("service", {160: decoder}))
    services.append(launch("parser", {161: parser, 167: delegated_parser}))
    services.append(launch("fetcher", {162: fetcher, 167: fetcher_parser}))
    client = launch("client", {160: app_decoder, 161: app_parser, 162: app_fetcher})
    for endpoint in (app_decoder, decoder, app_parser, parser, app_fetcher, fetcher, fetcher_parser, delegated_parser):
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
