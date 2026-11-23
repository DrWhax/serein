#!/usr/bin/env python3
"""Run call-link credential interoperability against Signal's HTTP frontend and an ephemeral local database."""
import argparse
from contextlib import ExitStack
import hashlib
import hmac
import json
import os
from pathlib import Path
import secrets
import socket
import subprocess
import tempfile
import time


def free_port(kind=socket.SOCK_STREAM):
    with socket.socket(socket.AF_INET, kind) as sock:
        sock.bind(("127.0.0.1", 0))
        return sock.getsockname()[1]


def start(stack, command, env, port, logs):
    process = subprocess.Popen(command, env=env, stdout=logs, stderr=subprocess.STDOUT)
    def stop():
        if process.poll() is None:
            process.terminate()
            try:
                process.wait(timeout=4)
            except subprocess.TimeoutExpired:
                process.kill()
                process.wait()
    stack.callback(stop)
    for _ in range(160):
        if process.poll() is not None:
            logs.flush()
            detail = Path(logs.name).read_text(errors="replace").splitlines()[-4:]
            raise RuntimeError(f"{Path(command[0]).name} exited before listening. " + " ".join(detail))
        try:
            with socket.create_connection(("127.0.0.1", port), timeout=0.2):
                return
        except OSError:
            time.sleep(0.05)
    raise RuntimeError("local test service did not start")


def run(args):
    import boto3
    db_port, front_port = free_port(), free_port()
    while db_port == front_port:
        front_port = free_port()
    database = f"http://127.0.0.1:{db_port}"
    frontend = f"http://127.0.0.1:{front_port}"
    # Only the first 16 bytes participate in the Signal room identifier.
    prk = hmac.digest(bytes(32), bytes(range(16)), hashlib.sha256)
    room = hmac.digest(prk, b"20230501-Signal-CallLinkRootKey-RoomId\x01", hashlib.sha256).hex()
    mock_params = os.environ.get("SEREIN_TEST_MOCK_ZK_PARAMS_FILE")
    if mock_params:
        secret = json.loads(Path(mock_params).read_text())["genericSecretParams"]
        fixture = None
    else:
        fixture = json.loads(subprocess.check_output([args.issuer, room]))
        secret = fixture.pop("server")
    env = dict(os.environ, AWS_ACCESS_KEY_ID="localtest", AWS_SECRET_ACCESS_KEY="localtest",
               AWS_EC2_METADATA_DISABLED="true", AWS_DEFAULT_REGION="us-west-1", NO_PROXY="127.0.0.1,localhost")
    with tempfile.TemporaryDirectory(prefix="serein-link-") as temp, ExitStack() as stack:
        if fixture is not None:
            path = Path(temp) / "credentials.json"
            path.write_text(json.dumps(fixture))
            env["SEREIN_TEST_LINK_CREDENTIALS"] = str(path)
        logs = stack.enter_context((Path(temp) / "services.log").open("wb"))
        backend_url = "http://127.0.0.1:9"
        if args.backend:
            # The production frontend contacts the selected backend at its IP on port 8080.
            with socket.socket() as probe:
                probe.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
                probe.bind(("127.0.0.1", 8080))
            udp_port = free_port(socket.SOCK_DGRAM)
            tcp_port = free_port()
            start(stack, [args.backend, "--binding-ip", "127.0.0.1", "--signaling-ip", "127.0.0.1",
                          "--signaling-port", "8080", "--ice-candidate-ip", "127.0.0.1",
                          "--ice-candidate-port", str(udp_port), "--ice-candidate-port-tcp", str(tcp_port)],
                  env, 8080, logs)
            backend_url = "http://127.0.0.1:8080"
            env["SEREIN_TEST_LINK_MEDIA"] = "1"
            env["SEREIN_TEST_SFU_UDP_PORT"] = str(udp_port)
            env["SEREIN_TEST_SFU_TCP_PORT"] = str(tcp_port)
        start(stack, [args.moto, "-H", "127.0.0.1", "-p", str(db_port)], env, db_port, logs)
        db = boto3.client("dynamodb", endpoint_url=database, region_name="us-west-1",
                          aws_access_key_id="localtest", aws_secret_access_key="localtest")
        db.create_table(TableName="Rooms", BillingMode="PAY_PER_REQUEST",
                        AttributeDefinitions=[{"AttributeName": k, "AttributeType": "S"} for k in ["roomId", "recordType", "region"]],
                        KeySchema=[{"AttributeName": "roomId", "KeyType": "HASH"}, {"AttributeName": "recordType", "KeyType": "RANGE"}],
                        GlobalSecondaryIndexes=[{"IndexName": "region-index", "KeySchema": [{"AttributeName": "region", "KeyType": "HASH"}],
                                                 "Projection": {"ProjectionType": "ALL"}}])
        start(stack, [args.frontend, "--server-ip", "127.0.0.1", "--server-port", str(front_port), "--internal-api-ip", "127.0.0.1",
                      "--region", "local", "--version", "test", "--cleanup-interval-ms", "60000", "--max-clients-per-call", "8", "--regional-url-template", frontend,
                      "--calling-server-url", backend_url, "--authentication-key", secrets.token_hex(32),
                      "--zkparams", secret, "--storage-table", "Rooms", "--storage-region", "us-west-1", "--storage-endpoint", database,
                      "--enable-call-link-epochs"], env, front_port, logs)
        return subprocess.call(args.command, env=dict(env, SEREIN_TEST_LINK_FRONTEND=frontend))


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--frontend", required=True, help="upstream calling_frontend executable")
    parser.add_argument("--backend", help="upstream calling_backend executable for media and room admission")
    parser.add_argument("--issuer", help="issue-test-credentials example binary")
    parser.add_argument("--moto", default="moto_server", help="moto_server executable")
    parser.add_argument("command", nargs=argparse.REMAINDER)
    args = parser.parse_args()
    if not args.command:
        parser.error("supply a test command to run")
    if not args.issuer and not os.environ.get("SEREIN_TEST_MOCK_ZK_PARAMS_FILE"):
        parser.error("supply --issuer or SEREIN_TEST_MOCK_ZK_PARAMS_FILE")
    raise SystemExit(run(args))
