"""Attribute the existing malloc-marker interval on selected HTTP workloads."""
from collections import Counter
from hashlib import sha256
import json
import os
from pathlib import Path
import re
import runpy
from tempfile import TemporaryDirectory

ROOT = Path(__file__).resolve().parent
CASES = (("normal-off", "binary"), ("single", "binary"),
         ("parallel-one", "binary"), ("expiry", "binary"))
COUNTS = {"normal-off": 160, "single": 24, "parallel-one": 24, "expiry": 24}
REGIONS = (
    ("task-local", r"swift_task_local|TaskLocal|HTTPRefreshContext"),
    ("refresh", r"registerRefresh|waitForRefresh|finishRefresh|RefreshWaiter|RefreshCallback"),
    ("deadline", r"HTTPCallDeadline|DispatchSource|_dispatch_source"),
    ("async-runtime", r"swift_task|swift_job|SwiftConcurrency"),
)
SEPARATOR = re.compile(r"\n(?=(?:ALLOC|FREE|VM_ALLOC|VM_DEALLOC) )")
SIZE = re.compile(r"\[size=(\d+)\]")
ADDRESS = re.compile(r"\b0x[0-9a-fA-F]+\b")
BUCKETS = [(name, re.compile(pattern, re.I)) for name, pattern in REGIONS]

def attribute(history, original):
    totals = original(history)
    buckets = {}
    stacks = {}
    marked = False
    for block in SEPARATOR.split(history):
        first, _, tail = block.partition("\n")
        if not first.startswith("ALLOC "):
            continue
        size = int(SIZE.search(first)[1])
        if "phaseStart()" in block:
            marked = True
            continue
        if "phaseEnd()" in block:
            marked = False
            continue
        if not marked:
            continue
        region = next((name for name, pattern in BUCKETS if pattern.search(block)), "other")
        tally = buckets.setdefault(region, [0, 0])
        tally[0] += 1
        tally[1] += size
        # Group stack text by symbols, without ASLR addresses or the allocation size.
        # Keep exact category totals and bounded examples in the hosted artifact.
        frame = ADDRESS.sub("@", SIZE.sub("", first) + "\n" + tail).strip()
        signature = sha256(frame.encode()).hexdigest()
        entry = stacks.setdefault((region, signature), [0, 0, frame[:480]])
        entry[0] += 1
        entry[1] += size
    assert sum(count for count, _ in buckets.values()) == totals["allocations"]
    assert sum(size for _, size in buckets.values()) == totals["requested_bytes"]
    representatives = {}
    for (region, signature), (count, size, example) in stacks.items():
        representatives.setdefault(region, []).append((size, count, signature, example))
    return {**totals, "history_sha256": sha256(history.encode()).hexdigest(),
            "buckets": buckets,
            "largest_stack_examples": {k: sorted(v, reverse=True)[:6] for k, v in representatives.items()}}

def main():
    measurement = runpy.run_path(str(ROOT / "measure.py"))
    helper = runpy.run_path(str(ROOT / "allocation-helper.py"))
    bindings = measurement["verify_bindings"]()
    base = helper["traced_allocations"]
    capture = helper["allocation_sample"]
    capture.__globals__.update(ROOT=ROOT, parse=measurement["parse"],
                               traced_allocations=lambda history: attribute(history, base))
    pairs = measurement["paired_samples"]
    pairs.__globals__["FORMAL"] = CASES
    env = {key: value for key, value in os.environ.items() if not key.startswith("MallocStackLogging")}
    rows = []
    with TemporaryDirectory(prefix="alloc-stacks.", dir=ROOT) as scratch:
        env.update(TMPDIR=scratch, LC_ALL="C", MallocStackLoggingNoCompact="1",
                   MallocStackLoggingDirectory=scratch)
        with (ROOT / "allocation-stacks.partial.jsonl").open("w") as journal:
            for row in pairs(lambda *args: capture(*args, env), COUNTS, 3):
                rows.append(row)
                journal.write(json.dumps(row) + "\n")
                journal.flush()
    assert len(rows) == 48 and measurement["verify_bindings"]() == bindings
    groups = Counter((r["scenario"], r["codec"], r["comparison"], r["block"]) for r in rows)
    assert len(groups) == 16 and set(groups.values()) == {3}
    capture_meta = {"sources": bindings, "stackToolSHA256": sha256(Path(__file__).read_bytes()).hexdigest(),
                    "bucketsUnit": ["allocation count", "requested bytes"], "samples": rows}
    (ROOT / "allocation-stacks.json").write_text(json.dumps(capture_meta, separators=(",", ":")) + "\n")

if __name__ == "__main__":
    main()
