"""Run with the path to the Linux TransportCheck executable."""
import os
import signal
import socket
import sys

binary = os.path.abspath(sys.argv[1])
client, server = socket.socketpair(socket.AF_UNIX, socket.SOCK_SEQPACKET)


def launch(mode, endpoint):
    actions = [(os.POSIX_SPAWN_DUP2, endpoint.fileno(), 160)]
    return os.posix_spawn(binary, [binary, mode], os.environ, file_actions=actions)


server_pid = launch("service", server)
server.close()
try:
    client_pid = launch("client", client)
    client.close()
    _, status = os.waitpid(client_pid, 0)
    sys.exit(os.waitstatus_to_exitcode(status))
finally:
    try:
        os.kill(server_pid, signal.SIGTERM)
    except ProcessLookupError:
        pass
    os.waitpid(server_pid, 0)
