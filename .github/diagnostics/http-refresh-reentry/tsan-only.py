#!/usr/bin/env python3
import argparse
import base64
from collections import Counter
import errno
from hashlib import sha256
import json
import os
from pathlib import Path
import pty
import re
import selectors
import signal
import subprocess
import sys
import tempfile
import time

PARENT = "5b8e3c8e946cd1c9059624a6f1e225f486ed90b3"
BASE = "d6578969bcef258141c7c99cb6cface30a22a0e2"
PINS = "b591abc67a0576311e15869bc841db99743f9f0398b6a8828e78984a86079fd2"
PATCHES = (
    ("candidate.patch", "5c26ee2f33344a2554faa9f905df4c9eed999d142b2fe5d3ae4745e9a9096024",
     "c106719f7f78608173fcbe522f90064552f32b4a"),
    ("optimization.patch", "ba9e4d01f2d6b665d77e19cd973fdfd9e7f5c84f8ebec9de4f7ffedf99e207fd",
     "8dd7fd238fbbb4bd195f2083650174339946d50a"),
)
DIRECT_OPERATION = ("direct-operation.patch", "ba174285c5bfc5b3d380d1e94fdc04f3062584106734d9eea4dd7bcf7d5722ca", "168f4f54dfeda7ae37d6a06c0754645ae98c792e")
ARMS = {
    "A": ("49921cd4b64e1b0fefef5d8440c1496406c3166e", "dbdaed8acd534ea691215f839b6e57a4504c333a", 34,
          "e680ff51fd60a4727aee06314bcc6e75ea902ffafab9f7cb37f2824f5599700c"),
    "Q": ("8dd7fd238fbbb4bd195f2083650174339946d50a", "e8bfbe73d97942739a3de11033202fcb5f5b437a", 37,
          "7bb72634c1c646bbb6601376807ad0c92e0ca53b32f64e780f475274454098bb"),
    "R": ("168f4f54dfeda7ae37d6a06c0754645ae98c792e", "bc45cfd3ea3c107c494fb3a76a9274e1a8324318", 37,
          "7bb72634c1c646bbb6601376807ad0c92e0ca53b32f64e780f475274454098bb"),
}
TEST_SOURCE = "Tests/LuxoClientTests/HTTPBackendTests.swift"
XCTEST = re.compile(r"^Test Case '-\[LuxoClientTests\.HTTPBackendTests (test\w+)\]' (started|passed|failed|skipped)\b", re.M)


def write_json(path, result):
    path.write_text(json.dumps(result, indent=2) + "\n")


def output(*argv):
    return subprocess.check_output(argv, text=True).strip()


def git(path, *args):
    return output("git", "--no-replace-objects", "-C", str(path), *args)


def digest(path):
    result = sha256()
    with path.open("rb") as reader:
        for chunk in iter(lambda: reader.read(1024 * 1024), b""):
            result.update(chunk)
    return result.hexdigest()


def verify_source(sdk, arm):
    tree, source_tree, _, fixture_hash = ARMS[arm]
    assert git(sdk, "rev-parse", "HEAD") == BASE
    assert git(sdk, "write-tree") == tree
    assert git(sdk, "rev-parse", f"{tree}:Sources/LuxoClient") == source_tree
    assert not git(sdk, "diff", "--name-only")
    assert digest(sdk / TEST_SOURCE) == fixture_hash
    assert digest(sdk / "Package.resolved") == PINS


def prepare(repo, input_dir, work, arm):
    sdk = work / "sdk"
    subprocess.run(["git", "clone", "-q", "--shared", "--no-checkout", str(repo), str(sdk)], check=True)
    git(sdk, "switch", "-q", "--detach", BASE)
    if arm != "A":
        patches = (*PATCHES, DIRECT_OPERATION) if arm == "R" else PATCHES
        for name, digest_pin, tree in patches:
            raw = base64.b64decode(b"".join((input_dir / (name + ".base64")).read_bytes().splitlines()), validate=True)
            assert sha256(raw).hexdigest() == digest_pin, name
            patch = work / name
            patch.write_bytes(raw)
            git(sdk, "apply", "--index", "--whitespace=error-all", str(patch))
            assert git(sdk, "write-tree") == tree, name
    pins = (input_dir / "pins.json").read_bytes()
    assert sha256(pins).hexdigest() == PINS
    (sdk / "Package.resolved").write_bytes(pins)
    verify_source(sdk, arm)
    tests = re.findall(r"^    func (test\w+)\(", (sdk / TEST_SOURCE).read_text(), re.M)
    assert len(tests) == len(set(tests)) == ARMS[arm][2]
    return sdk, tests


def cleanup_group(pid):
    for sig in (signal.SIGTERM, signal.SIGKILL):
        try:
            os.killpg(pid, sig)
        except ProcessLookupError:
            return
        if sig == signal.SIGTERM:
            time.sleep(1)


def process_snapshot(pid, destination):
    result = subprocess.run(["ps", "-axo", "pid=,ppid=,pgid=,state=,etime=,comm="], text=True,
                            stdout=subprocess.PIPE, check=True, timeout=3)
    rows = [line for line in result.stdout.splitlines() if len(line.split(maxsplit=3)) >= 4 and line.split()[2] == str(pid)]
    destination.write_text("\n".join(rows) + "\n")


def watchdog(argv, cwd, env, out, phase, limit):
    start = time.monotonic()
    master, slave = pty.openpty()
    transcript = out / f"{phase}.log"
    timeout = False
    cleanup_error = None
    print(f"Starting {phase} with a {limit}s watchdog", flush=True)
    with transcript.open("wb") as log, selectors.DefaultSelector() as selector:
        try:
            child = subprocess.Popen(argv, cwd=cwd, env=env, stdout=slave, stderr=slave, stdin=subprocess.DEVNULL,
                                     start_new_session=True)
        except BaseException:
            os.close(master)
            raise
        finally:
            os.close(slave)
        try:
            selector.register(master, selectors.EVENT_READ)
            while True:
                remaining = limit - (time.monotonic() - start)
                if remaining <= 0:
                    timeout = True
                    break
                if not selector.select(min(remaining, 1)):
                    continue
                try:
                    data = os.read(master, 8192)
                except OSError as err:
                    if err.errno != errno.EIO:
                        raise
                    break
                if not data:
                    break
                log.write(data)
                log.flush()
                if phase == "test":
                    sys.stdout.buffer.write(data)
                    sys.stdout.buffer.flush()
            if not timeout:
                try:
                    child.wait(timeout=max(0.1, limit - (time.monotonic() - start)))
                except subprocess.TimeoutExpired:
                    timeout = True
        finally:
            if timeout:
                snapshot = out / f"{phase}-owned-processes.txt"
                try:
                    process_snapshot(child.pid, snapshot)
                except (OSError, subprocess.SubprocessError) as err:
                    snapshot.write_text(f"Process snapshot unavailable: {err}\n")
            os.close(master)
            try:
                if timeout or child.poll() is None:
                    cleanup_group(child.pid)
                child.wait(timeout=5)
            except (PermissionError, subprocess.TimeoutExpired) as err:
                cleanup_error = str(err)
    record = {"argv": argv, "exit": child.returncode, "timedOut": timeout, "cleanupError": cleanup_error,
              "limitSeconds": limit, "elapsedSeconds": round(time.monotonic() - start, 3)}
    write_json(out / f"{phase}.json", record)
    print(f"Finished {phase}: exit={record['exit']} timedOut={timeout} elapsed={record['elapsedSeconds']}s", flush=True)
    return record


def test_progress(log, tests):
    text = log.read_text(errors="replace")
    events = [{"test": name, "status": status} for name, status in XCTEST.findall(text)]
    started = Counter(row["test"] for row in events if row["status"] == "started")
    passed = Counter(row["test"] for row in events if row["status"] == "passed")
    t_san_error = bool(re.search(r"(?m)^(WARNING|FATAL): ThreadSanitizer", text))
    finished = all(row["status"] in ("started", "passed") for row in events)
    return {"expected": tests, "events": events, "last": events[-1] if events else None,
            "tsanDiagnostic": t_san_error,
            "complete": started == passed == Counter(tests) and finished and not t_san_error}


def native_toolchain(out):
    env = os.environ
    assert (env["RUNNER_OS"], env["RUNNER_ARCH"], env["DEVELOPER_DIR"]) == (
        "macOS", "ARM64", "/Applications/Xcode_26.6.app/Contents/Developer")
    xcode = output("xcodebuild", "-version")
    swift = output("swift", "--version")
    sdk = output("xcrun", "--sdk", "macosx", "--show-sdk-version")
    os_version = output("sw_vers", "-productVersion")
    cpu = subprocess.run(["sysctl", "-n", "machdep.cpu.brand_string"], text=True, capture_output=True)
    (out / "toolchain.txt").write_text("\n".join((output("uname", "-a"), output("sw_vers"),
        cpu.stdout.strip() or "CPU brand unavailable", xcode, swift, f"SDK {sdk}",
        f"ImageOS={env.get('ImageOS', '')} ImageVersion={env.get('ImageVersion', '')}")) + "\n")
    assert os_version.split(".", 1)[0] == "26" and output("uname", "-m") == "arm64"
    assert xcode.splitlines() == ["Xcode 26.6", "Build version 17F113"]
    assert swift.startswith("Apple Swift version 6.3.3 ") and sdk == "26.5"


def native_test(sdk, work, out, tests, arm):
    local_tmp = work / "tmp"
    local_tmp.mkdir()
    env = {**os.environ, "TMPDIR": str(local_tmp), "TERM": "dumb", "NO_COLOR": "1"}
    common = ["--disable-sandbox", "--disable-automatic-resolution", "--scratch-path", str(work / "build"),
              "--cache-path", str(work / "cache"), "-j", "2"]
    sanitized = [*common, "--sanitize=thread", "-Xswiftc", "-warnings-as-errors"]
    phases = [("resolve", 180, ["swift", "package", *common, "resolve"]),
              ("build", 780, ["swift", "build", *sanitized, "--build-tests"])]
    for phase, limit, argv in phases:
        status = watchdog(argv, sdk, env, out, phase, limit)
        if status["exit"] != 0 or status["timedOut"] or status["cleanupError"]:
            return 124 if status["timedOut"] else 1
        verify_source(sdk, arm)

    bundles = (work / "build").rglob("LuxoClientPackageTests.xctest")
    binaries = {(bundle / "Contents/MacOS/LuxoClientPackageTests").resolve(strict=True) for bundle in bundles}
    binary, = binaries
    linkage = output("xcrun", "otool", "-L", str(binary))
    (out / "test-binary.txt").write_text(f"{digest(binary)} {binary}\n{linkage}\n")
    assert "libclang_rt.tsan" in linkage
    command = ["swift", "test", *sanitized, "--skip-build", "--no-parallel", "--filter", "HTTPBackendTests"]
    run = watchdog(command, sdk, env, out, "test", 180)
    progress = test_progress(out / "test.log", tests)
    write_json(out / "test-progress.json", progress)
    verify_source(sdk, arm)
    assert digest(binary) == (out / "test-binary.txt").read_text().split()[0]
    if run["timedOut"]:
        return 124
    return int(run["exit"] != 0 or bool(run["cleanupError"]) or not progress["complete"])


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("arm", choices=ARMS)
    parser.add_argument("--prepare-only", action="store_true")
    args = parser.parse_args()
    os.umask(0o077)
    input_dir = Path(__file__).resolve().parent
    repo = input_dir.parents[2]
    out = repo / ".tmp" / f"http-refresh-tsan-{args.arm}"
    out.mkdir(parents=True)
    revision = git(repo, "rev-parse", "HEAD")
    if args.prepare_only:
        assert revision == PARENT
    else:
        assert revision == os.environ["GITHUB_SHA"]
        assert git(repo, "show", "-s", "--format=%P", revision) == PARENT
        native_toolchain(out)
    with tempfile.TemporaryDirectory(prefix="tsan-source-", dir=out.parent) as scratch:
        work = Path(scratch)
        sdk, tests = prepare(repo, input_dir, work, args.arm)
        write_json(out / "source.json", {"arm": args.arm, "diagnostic": revision, "base": BASE,
                   "tree": ARMS[args.arm][0], "clientTree": ARMS[args.arm][1], "pinsSha256": PINS,
                   "fixtureSha256": ARMS[args.arm][3], "tests": tests,
                   "changedPaths": git(sdk, "diff", "--cached", "--name-only").splitlines()})
        return 0 if args.prepare_only else native_test(sdk, work, out, tests, args.arm)


def terminate(signum, _frame):
    raise SystemExit(128 + signum)


if __name__ == "__main__":
    signal.signal(signal.SIGTERM, terminate)
    raise SystemExit(main())
