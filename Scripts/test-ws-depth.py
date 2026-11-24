"""Validate native Codable JSON depth against an owned core WebSocket peer."""
import argparse
import hashlib
import json
import os
from pathlib import Path
import re
import selectors
import subprocess
import tempfile
import time


def source_hashes(root, core):
    files = [root / "Package.swift", root / "Package.resolved", Path(__file__).resolve()]
    for name in ["Sources", "Tests"]:
        for directory, subdirectories, names in os.walk(root / name):
            subdirectories[:] = sorted(name for name in subdirectories if name not in {".build", ".tmp", ".git"})
            files.extend(Path(directory) / name for name in sorted(names) if name.endswith(".swift"))
    result = {"swift/" + str(path.relative_to(root)): hashlib.sha256(path.read_bytes()).hexdigest()
              for path in files}
    core_files = [core / "go.mod", core / "go.sum", *sorted((core / "tests/sdk-interop/ws-codable").glob("*.go"))]
    for path in core_files:
        result["core/" + str(path.relative_to(core))] = hashlib.sha256(path.read_bytes()).hexdigest()
    return result


def stage(output, ledger, name, command, cwd, environment=None, timeout=120):
    started = time.monotonic()
    with (output / (name + ".log")).open("w") as log:
        result = subprocess.run(command, cwd=cwd, env=environment, stdout=log, stderr=log, timeout=timeout)
    ledger["stages"].append({"name": name, "command": command, "exit": result.returncode,
                             "elapsed_s": time.monotonic() - started})
    if result.returncode != 0:
        raise RuntimeError(name + " failed; see " + str(output))


def stop_peer(server, ledger):
    if server is None:
        return
    try:
        server.stdin.close()
    except BrokenPipeError:
        pass
    try:
        ledger["server_exit"] = server.wait(timeout=10)
    except subprocess.TimeoutExpired:
        server.terminate()
        ledger["server_exit"] = server.wait(timeout=5)
        ledger["status"] = "failed_cleanup"
    server.stdout.close()
    if ledger["server_exit"] != 0:
        ledger["status"] = "failed_cleanup"


def main():
    root = Path(__file__).resolve().parents[1]
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--core", type=Path, default=root.parent / "luxo", help="Luxo core checkout")
    args = parser.parse_args()
    core = args.core.resolve()
    if not (core / "tests/sdk-interop/ws-codable/main.go").is_file():
        parser.error("--core must contain the ws-codable fixture; no dependency is installed by this harness")
    temporary = root / ".tmp"
    temporary.mkdir(exist_ok=True)
    output = Path(tempfile.mkdtemp(prefix="swift-ws-codable-", dir=temporary))
    binary = output / "peer"
    server = None
    ledger = {"status": "failed", "output": str(output), "stages": [], "fixture_race": True}
    options = ["--disable-sandbox", "--package-path", str(root), "--scratch-path", str(root / ".build"),
               "--disable-automatic-resolution", "-j", "2", "-Xswiftc", "-warnings-as-errors",
               "--enable-code-coverage"]
    try:
        ledger["source_sha256"] = source_hashes(root, core)
        stage(output, ledger, "swift-build", ["swift", "build", "--build-tests", *options], root, timeout=600)
        stage(output, ledger, "go-build", ["go", "build", "-race", "-o", str(binary),
                                          "./tests/sdk-interop/ws-codable"], core)
        stage(output, ledger, "go-vet", ["go", "vet", "./tests/sdk-interop/ws-codable"], core)
        stage(output, ledger, "go-test", ["go", "test", "-race", "-count=1",
                                         "./tests/sdk-interop/ws-codable"], core)
        with (output / "server.log").open("w") as server_log:
            server = subprocess.Popen([str(binary)], cwd=core, stdin=subprocess.PIPE, stdout=subprocess.PIPE,
                                      stderr=server_log, text=True)
            with selectors.DefaultSelector() as selector:
                selector.register(server.stdout, selectors.EVENT_READ)
                if not selector.select(timeout=10):
                    raise RuntimeError("WS peer did not become ready")
            endpoint = server.stdout.readline().strip()
            if not endpoint.startswith("ws://127.0.0.1:"):
                raise RuntimeError("Unexpected WS peer endpoint")
            environment = dict(os.environ, LUXO_WS_CODABLE_URL=endpoint)
            stage(output, ledger, "test", ["swift", "test", "--skip-build", *options, "--filter",
                                          "WebSocketDecodeTests.testLiveGoPeer"], root, environment, timeout=90)
            text = (output / "test.log").read_text()
            counts = re.findall(r"Executed (\d+) tests, with 0 failures", text)
            if "skipped" in text or not counts or int(counts[-1]) != 2:
                raise RuntimeError("Expected both live WS tests with zero failures and skips")
            ledger["tests"] = 2
            if source_hashes(root, core) != ledger["source_sha256"]:
                raise RuntimeError("WS fixture or Swift input changed during verification")
            if "WARNING: DATA RACE" in (output / "server.log").read_text():
                raise RuntimeError("Go peer race detected")
            ledger["status"] = "passed"
    finally:
        try:
            stop_peer(server, ledger)
        finally:
            if binary.exists():
                binary.resolve().relative_to(temporary.resolve())
                ledger["removed_binary"] = {"sha256": hashlib.sha256(binary.read_bytes()).hexdigest(),
                                             "bytes": binary.stat().st_size}
                binary.unlink()
            (output / "result.json").write_text(json.dumps(ledger, indent=2) + "\n")
            print(json.dumps(ledger | {"source_sha256": "see result.json"}))
    if ledger["status"] != "passed":
        raise RuntimeError("WS peer cleanup failed")


if __name__ == "__main__":
    main()
