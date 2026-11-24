"""Own the extra loopback peers required by the full Swift test suite."""

from contextlib import ExitStack, contextmanager
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
import json
import os
import selectors
import subprocess
from threading import Lock, Thread
import time
from urllib.parse import urlsplit


def ready_line(stream):
    deadline = time.monotonic() + 10
    line = b""
    with selectors.DefaultSelector() as selector:
        selector.register(stream, selectors.EVENT_READ)
        while len(line) < 4096:
            left = deadline - time.monotonic()
            if left <= 0 or not selector.select(left):
                raise RuntimeError("fixture readiness timed out")
            data = os.read(stream.fileno(), 4096 - len(line))
            if not data:
                break
            line += data
            if b"\n" in line:
                return line.split(b"\n", 1)[0].decode("ascii")
    raise RuntimeError("fixture did not report a complete endpoint")


def loopback_endpoint(stream, scheme, path):
    endpoint = ready_line(stream)
    address = urlsplit(endpoint)
    if (address.scheme, address.hostname, address.path) != (scheme, "127.0.0.1", path):
        raise RuntimeError("unexpected loopback fixture endpoint")
    if not address.port or address.netloc != f"127.0.0.1:{address.port}" or address.query or address.fragment:
        raise RuntimeError("invalid loopback fixture endpoint")
    return endpoint


def stop_peer(process):
    try:
        process.stdin.close()
        try:
            status = process.wait(timeout=8)
        except subprocess.TimeoutExpired:
            process.terminate()
            try:
                process.wait(timeout=3)
            except subprocess.TimeoutExpired:
                process.kill()
                process.wait(timeout=3)
            raise RuntimeError("loopback fixture did not stop after stdin closed")
        if status != 0:
            raise RuntimeError(f"loopback fixture stopped with exit {status}")
    finally:
        process.stdout.close()


@contextmanager
def managed_peer(binary, log_path, *arguments):
    with log_path.open("w") as log:
        process = subprocess.Popen([str(binary), *map(str, arguments)], stdin=subprocess.PIPE, stdout=subprocess.PIPE, stderr=log)
        try:
            yield process
        finally:
            stop_peer(process)
    if "WARNING: DATA RACE" in log_path.read_text():
        raise RuntimeError(f"race detected in {binary.name} fixture")


def build_core_peers(root, core, output):
    environment = dict(os.environ, GOWORK="off")
    peers = {
        "ws-codable": "./tests/sdk-interop/ws-codable",
        "ws-renewal": str(root / "Tests/Fixtures/WSRenewal/main.go"),
    }
    with (output / "core-fixture-build.log").open("w") as log:
        for name, source in peers.items():
            subprocess.run(
                ["go", "build", "-race", "-trimpath", "-o", str(output / name), source],
                cwd=core, env=environment, check=True, timeout=180, stdout=log, stderr=log,
            )


class RedirectFixture:
    def __init__(self):
        self.lock = Lock()
        self.replays = []
        self.valid_requests = 0
        self.base = ""
        self.cross = ""

    def source_response(self, method, path, headers, body):
        if method == "GET" and path.path in ("/redirect", "/schema"):
            if headers.get("X-Introspection-Key") != "test-secret":
                return 400, {}, b""
            if path.path == "/schema":
                return 200, {"Content-Type": "application/json"}, b'{"models":{},"apis":{}}'
            return 302, {"Location": self.cross + "/target"}, b""

        status = path.path.removeprefix("/redirect/")
        if method == "POST" and status in {"301", "302", "303", "307", "308"}:
            if headers.get("X-Project-Key") != "test-only-key" or body != b"private-input":
                return 400, {}, b""
            origin = {"same": self.base, "cross": self.cross}.get(path.query)
            if origin is not None:
                return int(status), {"Location": origin + "/target"}, b""
        return 404, {}, b""

    def response(self, method, path, headers, body):
        if path.path in ("/captured", "/target"):
            with self.lock:
                if path.path == "/target":
                    self.replays.append(method)
                return 200, {"Content-Type": "application/json"}, json.dumps(self.replays).encode()
        status, response_headers, payload = self.source_response(method, path, headers, body)
        if status in (200, 301, 302, 303, 307, 308):
            with self.lock:
                self.valid_requests += 1
        return status, response_headers, payload

    def verify(self):
        with self.lock:
            if self.valid_requests != 22 or self.replays:
                raise RuntimeError(f"redirect fixture observed {self.valid_requests} source requests and "
                                   f"{len(self.replays)} replays")


def redirect_handler(fixture):
    class Handler(BaseHTTPRequestHandler):
        def do_GET(self):
            self.respond()

        def do_POST(self):
            self.respond()

        def respond(self):
            try:
                length = int(self.headers.get("Content-Length", "0"))
            except ValueError:
                self.send_error(400)
                return
            if not 0 <= length <= 1024:
                self.send_error(400)
                return
            self.connection.settimeout(5)
            status, headers, data = fixture.response(
                self.command, urlsplit(self.path), self.headers, self.rfile.read(length))
            self.send_response(status)
            for key, value in headers.items():
                self.send_header(key, value)
            self.send_header("Content-Length", str(len(data)))
            self.end_headers()
            self.wfile.write(data)

        def log_message(self, *args):
            pass

    return Handler


@contextmanager
def redirect_server(fixture):
    with ThreadingHTTPServer(("127.0.0.1", 0), redirect_handler(fixture)) as server:
        worker = Thread(target=server.serve_forever, kwargs={"poll_interval": 0.05})
        worker.start()
        try:
            yield f"http://127.0.0.1:{server.server_port}"
        finally:
            server.shutdown()
            worker.join()


@contextmanager
def full_test_environment(root, core, output, environment):
    build_core_peers(root, core, output)
    redirect = RedirectFixture()
    with ExitStack() as stack:
        redirect.base = stack.enter_context(redirect_server(redirect))
        redirect.cross = stack.enter_context(redirect_server(redirect))
        codable = stack.enter_context(managed_peer(output / "ws-codable", output / "ws-codable.log"))
        renewal = stack.enter_context(managed_peer(output / "ws-renewal", output / "ws-renewal.log"))
        yield dict(environment, LUXO_CODEGEN_REDIRECT_URL=redirect.base, LUXO_HTTP_REDIRECT_URL=redirect.base,
                   LUXO_WS_CODABLE_URL=loopback_endpoint(codable.stdout, "ws", "/ws"),
                   LUXO_WS_RENEWAL_URL=loopback_endpoint(renewal.stdout, "http", ""), LUXO_WS_RENEWAL_STREAM="1")
        redirect.verify()


def core_revision(core, expected):
    if not core or not expected or not (core / "tests/sdk-interop/ws-codable/main.go").is_file():
        raise RuntimeError("full Swift validation requires a pinned Core fixture checkout")
    actual = subprocess.check_output(["git", "rev-parse", "HEAD"], cwd=core, text=True, timeout=10).strip()
    if actual != expected:
        raise RuntimeError(f"Core fixture checkout is {actual}, expected {expected}")
    status = subprocess.check_output(
        ["git", "status", "--porcelain", "--untracked-files=all"], cwd=core, text=True, timeout=10)
    if status:
        raise RuntimeError("Core fixture checkout contains unexpected changes")
    return actual
