"""Private UDP and TLS peer for check.c. Run in a separate test container."""
from pathlib import Path
import socket
import ssl
import sys
import threading

host, port, certdir = sys.argv[1], int(sys.argv[2]), Path(sys.argv[3])
tls = ssl.SSLContext(ssl.PROTOCOL_TLS_SERVER)
tls.load_cert_chain(certdir / "server.pem", certdir / "server.key")

def serve_tls():
    with socket.socket() as listener:
        listener.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
        listener.bind((host, port))
        listener.listen()
        while True:
            client, _ = listener.accept()
            with client:
                try:
                    with tls.wrap_socket(client, server_side=True) as stream:
                        message = stream.recv(256)
                        if message:
                            stream.sendall(message)
                except (ssl.SSLError, ConnectionError):
                    continue

threading.Thread(target=serve_tls, daemon=True).start()
with socket.socket(socket.AF_INET, socket.SOCK_DGRAM) as udp:
    udp.bind((host, port))
    while True:
        hello, address = udp.recvfrom(256)
        if hello != b"ice":
            continue
        udp.sendto(hello, address)
        with socket.socket(socket.AF_INET, socket.SOCK_DGRAM) as inbound:
            inbound.bind((host, 0))
            inbound.settimeout(5)
            inbound.sendto(b"offer", address)
            try:
                reply, source = inbound.recvfrom(256)
                if source == address and reply == b"answer":
                    inbound.sendto(b"done", address)
            except TimeoutError:
                continue
