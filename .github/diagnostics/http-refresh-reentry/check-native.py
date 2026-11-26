"""Validate the actual full SwiftPM fixture and the HTTP tests from raw XCTest."""
import hashlib
import json
from pathlib import Path
import re
import sys

out, stage = Path(sys.argv[1]), sys.argv[2]
cases = {
    "testRefreshCallbackReturnsItsNestedUnauthorizedErrorWithoutWaitingOnItself",
    "testNestedTransportRefreshKeepsTheAncestorUnauthorizedError",
    "testTaskInheritingRetiredRefreshCanRefreshTheNewCredentialRevision",
    "testThreeRequestsShareRefreshAndLate401RetriesOnlyOnce",
}
log = (out / ("test.log" if stage == "full" else "http-tsan.log")).read_text()
passed = set(re.findall(r"Test Case '-\[LuxoClientTests\.HTTPBackendTests (\w+)\]' passed", log))
assert len(passed) >= 37 and cases <= passed, (stage, len(passed), cases - passed)
counts = re.findall(r"Executed (\d+) tests, with 0 failures", log)
assert counts and not re.search(r"\bskipped\b", log, re.IGNORECASE), stage
if stage == "full":
    result = json.loads((out / "result.json").read_text())
    assert result["status"] == "passed" and result["formal_sdk"]
    assert result["credentials_removed"]
    assert result["server_exit"] == 0
    assert result["tests"] == int(counts[-1])
    assert result["core_fixture_revision"] == "a2c411b7b83ca233881ace0c5bf3bec0b9646e1d"
    digest = hashlib.sha256((out / "pins.json").read_bytes()).hexdigest()
    assert result["sdk_source_sha256"]["Package.resolved"] == digest
else:
    assert int(counts[-1]) == len(passed) == 37
    assert "WARNING: ThreadSanitizer" not in log
print(f"{stage}: {counts[-1]} passed, {len(passed)} HTTP, all 4 lifecycle regressions")
