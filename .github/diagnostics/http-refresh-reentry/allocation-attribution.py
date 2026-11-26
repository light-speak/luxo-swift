"""Attribute every in-window malloc request with the pinned HTTP refresh probe."""

from collections import Counter, defaultdict
import gzip
from hashlib import sha256
import json
import os
from pathlib import Path
import re
import runpy
from statistics import median
from tempfile import TemporaryDirectory

ROOT = Path(__file__).resolve().parent
LEAVES = {
    ("normal-off", "json"): 160,
    ("single", "binary"): 24,
    ("parallel-one", "json"): 24,
    ("expiry", "json"): 24,
}
COMPARISONS = {"AA": ("base", "base"), "VV": ("next", "next"), "AV": ("base", "next")}
PAIRS = 3
EVENTS = re.compile(r"\n(?=(?:ALLOC|FREE|VM_ALLOC|VM_DEALLOC) )")
SIZE = re.compile(r"\[size=(\d+)\]")
FRAME = re.compile(r"^\s*\d+\s+\S+\s+")
ADDRESS = re.compile(r"\b0x[0-9a-fA-F]+\b")
OFFSET = re.compile(r" \+ \d+$")
REGIONS = {
    "task-local": r"swift_task_local|TaskLocal|HTTPRefreshContext",
    "refresh": r"registerRefresh|waitForRefresh|finishRefresh|RefreshWaiter|RefreshCallback",
    "deadline": r"HTTPCallDeadline|DispatchSource|_dispatch_source",
    "swift-task-slab": r"StackAllocator<|TaskAllocator|swift_task_alloc",
    "objc-autorelease": r"AutoreleasePool|objc_autorelease",
    "foundation": r"Foundation|CFNetwork|URLSession",
    "async-runtime": r"swift_task|swift_job|SwiftConcurrency|libswift_Concurrency",
    "probe-backend": r"ProbeBackend",
}


def stack_frames(tail):
    frames = []
    for line in tail.splitlines():
        if FRAME.match(line):
            line = OFFSET.sub("", ADDRESS.sub("@", line.strip()))
            frames.append(" ".join(line.split()))
    return frames or ["<stack unavailable>"]


def attribute(history, original, sites):
    totals = original(history)
    counts = defaultdict(Counter)
    active = False
    for event in EVENTS.split(history):
        header, _, tail = event.partition("\n")
        if not header.startswith("ALLOC "):
            continue
        if "phaseStart()" in event:
            active = True
            continue
        if "phaseEnd()" in event:
            active = False
            continue
        if not active:
            continue
        size = int(SIZE.search(header)[1])
        frames = stack_frames(tail)
        joined = "\n".join(frames)
        signature = sha256(joined.encode()).hexdigest()
        if signature not in sites:
            tags = [name for name, pattern in REGIONS.items() if re.search(pattern, joined, re.I)]
            sites[signature] = {"frames": frames, "tags": tags,
                                "region": tags[0] if tags else "other"}
        counts[signature][size] += 1

    events = sum(sum(sizes.values()) for sizes in counts.values())
    requested = sum(size * count for sizes in counts.values() for size, count in sizes.items())
    assert (events, requested) == (totals["allocations"], totals["requested_bytes"])
    return {**totals, "history_sha256": sha256(history.encode()).hexdigest(), "stackCountsBySize": counts}


def paired_samples(capture, equivalent):
    sets = list(COMPARISONS)
    for block in range(2):
        for scenario, codec in LEAVES:
            for index in range(PAIRS):
                flip = (block + index) % 2 == 1
                rotate = (block + index) % len(sets)
                schedule = sets[rotate:] + sets[:rotate]
                if flip:
                    schedule.reverse()
                for comparison in schedule:
                    roles = COMPARISONS[comparison]
                    meta = dict(block=block + 1, pair=index + 1, scenario=scenario, codec=codec,
                                comparison=comparison, order="VA" if flip else "AV")
                    arms = [None, None]
                    for arm in (1, 0) if flip else (0, 1):
                        arms[arm] = capture(roles[arm], scenario, codec, LEAVES[scenario, codec], meta, arm)
                    equivalent(*arms)
                    yield {**meta, "left": arms[0], "right": arms[1]}


def regions(arm, sites):
    result = defaultdict(lambda: [0, 0])
    for signature, sizes in arm["stackCountsBySize"].items():
        totals = result[sites[signature]["region"]]
        totals[0] += sum(sizes.values())
        totals[1] += sum(size * count for size, count in sizes.items())
    return result


def summarize(rows, sites):
    groups = defaultdict(list)
    for row in rows:
        key = "/".join(str(row[field]) for field in ("scenario", "codec", "comparison", "block"))
        left, right = (regions(row[arm], sites) for arm in ("left", "right"))
        group = {}
        count = row["left"]["iterations"]
        for region in left.keys() | right.keys():
            group[region] = [(right[region][i] - left[region][i]) / count for i in range(2)]
        group["all"] = [sum(values[i] for values in group.values()) for i in range(2)]
        groups[key].append(group)
    return {
        key: {
            region: [dict(median=median(values), min=min(values), max=max(values),
                          positives=sum(value > 0 for value in values))
                     for values in zip(*(r.get(region, [0, 0]) for r in group))]
            for region in sorted(set().union(*group))
        }
        for key, group in groups.items()
    }


def record_history(path, history):
    data = history.encode()
    with path.open("xb") as raw:
        with gzip.GzipFile(filename="", fileobj=raw, mode="wb", mtime=0) as compressed:
            compressed.write(data)


def main():
    measurement = runpy.run_path(str(ROOT / "measure.py"))
    helper = runpy.run_path(str(ROOT / "allocation-helper.py"))
    bindings = measurement["verify_bindings"]()
    original = helper["traced_allocations"]
    capture = helper["allocation_sample"]
    capture.__globals__.update(ROOT=ROOT, parse=measurement["parse"])
    env = {key: value for key, value in os.environ.items() if not key.startswith("MallocStackLogging")}
    sites = {}
    rows = []
    written_sites = set()
    process_ids = set()
    witness = ROOT / "allocation-attribution-raw"
    witness.mkdir()

    def trace(role, scenario, codec, count, meta, arm):
        def read_history(history):
            row = attribute(history, original, sites)
            if (meta["comparison"], meta["block"], meta["pair"]) == ("AV", 1, 1):
                name = f"{scenario}-{codec}-{role}.txt.gz"
                record_history(witness / name, history)
                row["rawWitness"] = name
            return row

        capture.__globals__["traced_allocations"] = read_history
        arm_data = capture(role, scenario, codec, count, env)
        assert arm_data["pid"] not in process_ids, arm_data["history_header"]
        process_ids.add(arm_data["pid"])
        return arm_data

    with TemporaryDirectory(prefix="alloc-attribution.", dir=ROOT) as scratch:
        env.update(TMPDIR=scratch, LC_ALL="C", MallocStackLoggingNoCompact="1",
                   MallocStackLoggingDirectory=scratch)
        with (ROOT / "allocation-attribution.partial.jsonl").open("w") as journal:
            for row in paired_samples(trace, measurement["ensure_equivalence"]):
                rows.append(row)
                # Include newly seen frame lists so the failure journal is usable alone.
                additions = {k: sites[k] for k in sorted(sites.keys() - written_sites)}
                written_sites.update(additions)
                journal.write(json.dumps({"row": row, "newSites": additions}, separators=(",", ":")) + "\n")
                journal.flush()
                if row["pair"] == PAIRS:
                    print(row["block"], row["scenario"], row["codec"], row["comparison"], flush=True)

    groups = Counter((r["scenario"], r["codec"], r["comparison"], r["block"]) for r in rows)
    assert len(groups) == len(LEAVES) * len(COMPARISONS) * 2 and set(groups.values()) == {PAIRS}
    assert len(rows) == 72 and len(process_ids) == 144 and len(list(witness.iterdir())) == 8
    assert measurement["verify_bindings"]() == bindings
    result = {"sources": bindings, "stackToolSHA256": sha256(Path(__file__).read_bytes()).hexdigest(),
              "sites": sites, "samples": rows, "units": ["allocations", "requested bytes"],
              "deltasPerOperationOrBatch": summarize(rows, sites)}
    (ROOT / "allocation-attribution.json").write_text(json.dumps(result, separators=(",", ":")) + "\n")


if __name__ == "__main__":
    main()
