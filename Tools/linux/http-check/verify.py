"""Run the production Linux HTTP client against a private, loopback-only HTTPS origin."""
import http.server
import pathlib
import shutil
import ssl
import subprocess
import tempfile
import threading
import time

here = pathlib.Path(__file__).resolve().parent
core = here.parents[2] / "Packages/SignalCore/Sources"

class Handler(http.server.BaseHTTPRequestHandler):
    def log_message(self, *_):
        pass

    def do_CONNECT(self):
        if self.path != "web-check.invalid:443":
            self.send_error(403)
            return
        self.send_response_only(200)
        self.end_headers()
        # The private test origin terminates TLS on this tunnel. No external
        # destination is contacted and an unproxied lookup of .invalid fails.
        with self.server.tls.wrap_socket(self.connection, server_side=True) as stream:
            Handler(stream, self.client_address, self.server)
        self.close_connection = True

    def do_HEAD(self):
        self.send_response(200)
        self.send_header("Content-Length", "6")
        self.end_headers()

    def do_POST(self):
        body = self.rfile.read(int(self.headers.get("Content-Length", "0")))
        self.send_response(200)
        self.send_header("X-Test", self.headers.get("X-Test", ""))
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)

    def do_GET(self):
        if self.path in ("/redirect", "/downgrade"):
            self.send_response(302)
            self.send_header("Location", "/bytes" if self.path == "/redirect" else "http://localhost/bytes")
            self.end_headers()
            return
        if self.path == "/slow":
            time.sleep(4)
            return
        body = b"abcdef"
        resume = self.path == "/bytes" and self.headers.get("Range") == "bytes=3-"
        self.send_response(206 if resume else 200)
        if resume:
            self.send_header("Content-Range", "bytes 3-5/6")
            body = body[3:]
        if self.path == "/chunked":
            self.send_header("Transfer-Encoding", "chunked")
            self.end_headers()
            self.wfile.write(b"6\r\nabcdef\r\n0\r\n\r\n")
        else:
            self.send_header("Content-Length", str(len(body)))
            self.end_headers()
            self.wfile.write(body)

def main():
    with tempfile.TemporaryDirectory() as temp:
        work = pathlib.Path(temp)
        target = work / "Sources/HTTPCheck"
        target.mkdir(parents=True)
        shutil.copy(here / "Package.swift", work)
        shutil.copy(here / "Sources/HTTPCheck/Check.swift", target)
        for name in ["CLibSoup", "CLinuxHTTP", "LinuxHTTP", "WebFetch"]:
            (work / "Sources" / name).symlink_to(here.parents[2] / "Packages/SignalMediaService/Sources" / name)
        for name in ["HTTPClient.swift", "LinuxHTTPSession.swift"]:
            (target / name).symlink_to(core / "SignalCore/Net" / name)
        tests = work / "Tests/DestinationPolicyTests"
        tests.mkdir(parents=True)
        (tests / "DestinationPolicyTests.swift").symlink_to(here.parents[2] / "Packages/SignalMediaService/Tests/SignalMediaDecoderTests/DestinationPolicyTests.swift")
        subprocess.run(["swift", "test", "--package-path", temp, "--filter", "DestinationPolicyTests"], check=True, timeout=120)
        def openssl(*args):
            subprocess.run(["openssl", *args], cwd=work, check=True, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
        for name in ["root", "other"]:
            openssl("req", "-x509", "-newkey", "rsa:2048", "-nodes", "-keyout", name+".key", "-out", name+".pem", "-days", "1", "-subj", "/CN="+name,
                    "-addext", "basicConstraints=critical,CA:TRUE", "-addext", "keyUsage=critical,keyCertSign,cRLSign")
            openssl("x509", "-in", name+".pem", "-outform", "DER", "-out", name+".der")
        openssl("req", "-newkey", "rsa:2048", "-nodes", "-keyout", "server.key", "-out", "server.csr", "-subj", "/CN=localhost")
        (work/"extensions").write_text("subjectAltName=DNS:localhost,DNS:web-check.invalid\nextendedKeyUsage=serverAuth\nbasicConstraints=CA:FALSE\n")
        openssl("x509", "-req", "-in", "server.csr", "-CA", "root.pem", "-CAkey", "root.key", "-CAcreateserial", "-out", "server.pem",
                "-days", "1", "-extfile", "extensions")
        with http.server.ThreadingHTTPServer(("127.0.0.1", 0), Handler) as server, \
             http.server.ThreadingHTTPServer(("127.0.0.1", 0), Handler) as proxy:
            ctx = ssl.SSLContext(ssl.PROTOCOL_TLS_SERVER)
            ctx.load_cert_chain(work/"server.pem", work/"server.key")
            proxy.tls = ctx
            threading.Thread(target=proxy.serve_forever, daemon=True).start()
            server.socket = ctx.wrap_socket(server.socket, server_side=True)
            threading.Thread(target=server.serve_forever, daemon=True).start()
            try:
                subprocess.run(["swift", "run", "--package-path", temp, "HTTPCheck", f"https://localhost:{server.server_port}", temp, str(proxy.server_port)], check=True, timeout=100)
            finally:
                proxy.shutdown()
                server.shutdown()

if __name__ == "__main__":
    main()
