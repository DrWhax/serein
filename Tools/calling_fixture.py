"""Loopback port and private PKI helpers for calling integration tests."""
import socket
import subprocess


def free_port(kind):
    with socket.socket(socket.AF_INET, kind) as probe:
        probe.bind(('127.0.0.1', 0))
        return probe.getsockname()[1]


def make_test_certificates(work):
    # Isolated trust root for a single run. Never install it in a keychain.
    config = work / 'cert.cnf'
    config.write_text("""[req]
prompt = no
distinguished_name = subject
[subject]
CN = Serein local TURN test
[root]
basicConstraints = critical,CA:true
keyUsage = critical,keyCertSign,cRLSign
[server]
basicConstraints = critical,CA:false
keyUsage = critical,digitalSignature,keyEncipherment
extendedKeyUsage = serverAuth
subjectAltName = DNS:localhost,DNS:relay.invalid
""")
    def openssl(*args):
        subprocess.run(['openssl', *args], check=True, cwd=work, capture_output=True)

    openssl('req', '-new', '-x509', '-newkey', 'rsa:2048', '-nodes', '-days', '2',
            '-config', 'cert.cnf', '-extensions', 'root', '-keyout', 'root.key', '-out', 'root.pem')
    openssl('req', '-new', '-newkey', 'rsa:2048', '-nodes', '-subj', '/CN=localhost',
            '-keyout', 'server.key', '-out', 'server.csr')
    openssl('x509', '-req', '-days', '1', '-in', 'server.csr', '-CA', 'root.pem', '-CAkey', 'root.key',
            '-CAcreateserial', '-extfile', 'cert.cnf', '-extensions', 'server', '-out', 'server.pem')
    openssl('x509', '-in', 'root.pem', '-outform', 'DER', '-out', 'root.der')
