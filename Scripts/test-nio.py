"""Validate the production Swift SDK against disposable Go TLS endpoints."""
import argparse
import hashlib
import json
import os
from pathlib import Path
import re
import shutil
import subprocess
import tempfile

from live_fixtures import core_revision, full_test_environment, managed_peer, ready_line


def source_hashes(root):
    files = [root / "Package.swift", root / "Package.resolved", Path(__file__).resolve(), root / "Scripts/live_fixtures.py",
             *sorted((root / "Sources").rglob("*.swift")),
             *sorted((root / "Tests").rglob("*.swift")),
             *sorted((root / "Tests/Fixtures/NIO").glob("*.go")),
             root / "Tests/Fixtures/WSRenewal/main.go"]
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
    endpoints = json.loads(ready_line(server.stdout))
    return dict(os.environ, LUXO_NIO_TEST_H2=endpoints["h2"], LUXO_NIO_TEST_H1=endpoints["h1"],
                LUXO_NIO_TEST_CERT=str(credentials / "server.crt"),
                LUXO_NIO_TEST_WRONG_CERT=str(credentials / "wrong/server.crt"))


FULL_FIXTURE_TESTS = {
    "CodegenTests testRealIntrospectionRejectsRedirect",
    "HTTPResponseCollectorTests testBusinessRedirectsDoNotReplayCredentialsOrBody",
    "WebSocketDecodeTests testLiveGoPeerCallsKeepNativeDepthBudgetsAndRecover",
    "WebSocketDecodeTests testLiveGoPeerStreamDepthFailureOnlyRetiresItsSubscription",
    "WebSocketRenewalTests testLiveGoExpiryRefreshAndReconnect",
    "WebSocketRenewalTests testLiveGoGatewayStreamExpiryNeverReplaysSubscriptions",
}


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
    return test_count((output / "test.log").read_text(), args.all)


def test_count(text, full):
    counts = re.findall(r"Executed (\d+) tests, with 0 failures", text)
    if re.search(r"\bskipped\b", text, re.IGNORECASE) or not counts or (not full and int(counts[-1]) != 39):
        raise RuntimeError("Expected all selected tests with zero failures and skips")
    if full:
        passed = set(re.findall(r"Test Case '-\[LuxoClientTests\.([^\]]+)\]' passed", text))
        missing = FULL_FIXTURE_TESTS - passed
        if missing:
            raise RuntimeError("Missing live suite results: " + ", ".join(sorted(missing)))
    return int(counts[-1])


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--all", action="store_true", help="Run all tests with TLS fixtures available")
    parser.add_argument("--coverage", action="store_true", help="Enable source coverage")
    parser.add_argument("--sanitize-thread", action="store_true", help="Enable Thread Sanitizer")
    parser.add_argument("--core", type=Path, help="Path to the pinned Core fixture checkout")
    parser.add_argument("--core-revision", help="Exact Core revision used to build the WebSocket peers")
    args = parser.parse_args()
    if args.all and (not args.core or not args.core_revision):
        parser.error("--all requires --core and --core-revision for the real WebSocket fixtures")
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
        with managed_peer(output / "server", output / "server.log", credentials / "server.crt",
                          credentials / "server.key") as server:
            environment = fixture_environment(server, credentials)
            if args.all:
                core = args.core.resolve()
                result["core_fixture_revision"] = core_revision(core, args.core_revision)
                with full_test_environment(root, core, output, environment) as complete:
                    result["tests"] = run_tests(root, output, complete, args)
                core_revision(core, args.core_revision)
            else:
                result["tests"] = run_tests(root, output, environment, args)
            if source_hashes(root) != result["sdk_source_sha256"]:
                raise RuntimeError("SDK input changed during integration")
        result["status"] = "passed"
    except (RuntimeError, ValueError, OSError, subprocess.SubprocessError):
        for name in ("build.log", "core-fixture-build.log", "server.log", "ws-codable.log", "ws-renewal.log",
                     "swift-build.log", "test.log"):
            log = output / name
            if log.is_file():
                print(f"{name}:\n{log.read_text(errors='replace')[-8000:]}", flush=True)
        raise
    finally:
        try:
            result["server_exit"] = None if server is None else server.returncode
            for name in ("server", "tlscert", "ws-codable", "ws-renewal"):
                (output / name).unlink(missing_ok=True)
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
