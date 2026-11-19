"""Validate the production Swift SDK against disposable Go TLS endpoints."""
import argparse
import hashlib
import json
import os
from pathlib import Path
import re
import selectors
import shutil
import subprocess
import tempfile


def source_hashes(root):
    files = [root / "Package.swift", root / "Package.resolved", Path(__file__).resolve(),
             *sorted((root / "Sources").rglob("*.swift")),
             *sorted((root / "Tests").rglob("*.swift")),
             *sorted((root / "Tests/Fixtures/NIO").glob("*.go"))]
    files = [path for path in files if not any(part in {".tmp", ".build", ".git"}
                                             for part in path.relative_to(root).parts)]
    return {str(path.relative_to(root)): hashlib.sha256(path.read_bytes()).hexdigest() for path in files}


def build_fixture(root, output, credentials):
    fixture = root / "Tests/Fixtures/NIO"
    with (output / "build.log").open("w") as log:
        for name, executable in [("certificate.go", "tlscert"), ("server.go", "server")]:
            subprocess.run(["go", "build", "-o", str(output / executable), str(fixture / name)],
                           cwd=root, check=True, timeout=120, stdout=log, stderr=log)
            subprocess.run(["go", "vet", str(fixture / name)], cwd=root, check=True,
                           timeout=120, stdout=log, stderr=log)
    wrong = credentials / "wrong"
    wrong.mkdir()
    for directory in [credentials, wrong]:
        subprocess.run([str(output / "tlscert"), str(directory)], check=True, timeout=10)


def fixture_environment(server, credentials):
    with selectors.DefaultSelector() as selector:
        selector.register(server.stdout, selectors.EVENT_READ)
        if not selector.select(timeout=10):
            raise RuntimeError("TLS fixture did not become ready")
    endpoints = json.loads(server.stdout.readline())
    return dict(os.environ, LUXO_NIO_TEST_H2=endpoints["h2"], LUXO_NIO_TEST_H1=endpoints["h1"],
                LUXO_NIO_TEST_CERT=str(credentials / "server.crt"),
                LUXO_NIO_TEST_WRONG_CERT=str(credentials / "wrong/server.crt"))


def run_tests(root, output, environment, args):
    options = ["--disable-sandbox", "--package-path", str(root),
               "--scratch-path", str(root / ".build"), "--disable-automatic-resolution",
               "-j", "2", "-Xswiftc", "-warnings-as-errors"]
    if args.coverage:
        options += ["--enable-code-coverage"]
    if args.sanitize_thread:
        options += ["--sanitize", "thread"]
    # Always compile current sources before using the no-build test invocation.
    # Cold dependency builds must not consume the network-test deadline.
    with (output / "swift-build.log").open("w") as log:
        subprocess.run(["swift", "build", "--build-tests", *options], cwd=root,
                       env=environment, check=True, timeout=600, stdout=log, stderr=log)
    command = ["swift", "test", "--skip-build", *options]
    if not args.all:
        command += ["--filter", "LuxoNIOTests"]
    with (output / "test.log").open("w") as log:
        subprocess.run(command, cwd=root, env=environment, check=True,
                       timeout=600 if args.all else 180, stdout=log, stderr=log)
    text = (output / "test.log").read_text()
    counts = re.findall(r"Executed (\d+) tests, with 0 failures", text)
    if "skipped" in text or not counts or (not args.all and int(counts[-1]) != 39):
        raise RuntimeError("Expected all selected tests with zero failures and skips")
    return int(counts[-1])


def stop_fixture(server, result):
    if server is None:
        return
    try:
        server.stdin.close()
    except BrokenPipeError:
        pass
    try:
        result["server_exit"] = server.wait(timeout=5)
    except subprocess.TimeoutExpired:
        server.terminate()
        result["server_exit"] = server.wait(timeout=5)
        result["status"] = "failed_cleanup"
    server.stdout.close()
    if result["server_exit"] != 0:
        result["status"] = "failed_cleanup"


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--all", action="store_true", help="Run all tests with TLS fixtures available")
    parser.add_argument("--coverage", action="store_true", help="Enable source coverage")
    parser.add_argument("--sanitize-thread", action="store_true", help="Enable Thread Sanitizer")
    args = parser.parse_args()
    root = Path(__file__).resolve().parents[1]
    temporary = root / ".tmp"
    temporary.mkdir(exist_ok=True)
    output = Path(tempfile.mkdtemp(prefix="swift-nio-integration-", dir=temporary))
    credentials = output / "credentials"
    credentials.mkdir()
    server = None
    result = {"status": "failed", "output": str(output), "formal_sdk": True}
    try:
        result["sdk_source_sha256"] = source_hashes(root)
        build_fixture(root, output, credentials)
        with (output / "server.log").open("w") as log:
            server = subprocess.Popen([str(output / "server"), str(credentials / "server.crt"),
                                       str(credentials / "server.key")], stdin=subprocess.PIPE,
                                      stdout=subprocess.PIPE, stderr=log, text=True)
            environment = fixture_environment(server, credentials)
            result["tests"] = run_tests(root, output, environment, args)
            if source_hashes(root) != result["sdk_source_sha256"]:
                raise RuntimeError("SDK input changed during integration")
            result["status"] = "passed"
    finally:
        try:
            stop_fixture(server, result)
        finally:
            credentials.resolve().relative_to(temporary.resolve())
            shutil.rmtree(credentials)
            result["credentials_removed"] = not credentials.exists()
            (output / "result.json").write_text(json.dumps(result, indent=2) + "\n")
            print(json.dumps(result | {"sdk_source_sha256": "see result.json"}))
    if result["status"] != "passed":
        raise RuntimeError("Integration cleanup failed")


if __name__ == "__main__":
    main()
