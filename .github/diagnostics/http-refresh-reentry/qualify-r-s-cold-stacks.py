"""Capture exact A/R/S refresh allocations on one native worker."""

from collections import Counter
from hashlib import sha256
import json
import os
from pathlib import Path
import runpy
import shutil
from tempfile import TemporaryDirectory

ROOT = Path(__file__).resolve().parent
WORKLOAD = ("single", "binary", 24)
COMPARISONS = {"AA": ("A", "A"), "RR": ("R", "R"), "SS": ("S", "S"),
               "AR": ("A", "R"), "RS": ("R", "S"), "AS": ("A", "S")}
IMAGES = {"A": "base", "R": "next", "S": "s"}
SOURCE_LINES = {"A": (212, 215), "R": (233, 237), "S": (234, 238)}
REGISTER = "specialized HTTPTransport.registerRefresh(_:_:after:)"
S_BINDINGS = {"bin/s", "s-sources.sha256", "s-source.txt", "qualify-r-s-cold-stacks.py"}


def components(arm, sites):
    registry = Counter(dict.fromkeys(("all24", "all1016", "taskSlabs1016", "callbackSlab",
                                      "register24", "weakBox", "refreshObjectCount",
                                      "refreshObjectBytes", "workerClosureCount", "workerClosureBytes"), 0))
    context_line, capture_line = SOURCE_LINES[arm["arm"]]
    for signature, hist in arm["stackCountsBySize"].items():
        frames = sites[signature]["frames"]
        registry["all24"] += hist.get(24, hist.get("24", 0))
        registry["all1016"] += hist.get(1016, hist.get("1016", 0))
        if any("swift::StackAllocator<" in frame for frame in frames):
            count = hist.get(1016, hist.get("1016", 0))
            registry["taskSlabs1016"] += count
            if any("thunk for @escaping @callee_guaranteed @async () -> (@owned String?)" in frame for frame in frames):
                registry["callbackSlab"] += count
        if any(REGISTER in frame for frame in frames):
            registry["register24"] += hist.get(24, hist.get("24", 0))
        if len(frames) < 5 or "swift_allocObject" not in frames[3] or REGISTER not in frames[4]:
            continue
        caller = frames[4]
        if caller.endswith("/<compiler-generated>:0"):
            registry["weakBox"] += hist.get(24, hist.get("24", 0))
        for name, line in (("refreshObject", context_line), ("workerClosure", capture_line)):
            if caller.endswith(f"HTTPTransport.swift:{line}"):
                registry[name + "Count"] += sum(hist.values())
                registry[name + "Bytes"] += sum(int(size) * count for size, count in hist.items())
    return dict(registry)


def require_components(result, arm):
    expected = WORKLOAD[2]
    width = {"A": (64, 48, 24), "R": (56, 64, 24), "S": (56, 64, 0)}
    context, closure, weak = width[arm]
    assert result["refreshObjectCount"] == result["workerClosureCount"] == expected
    assert result["refreshObjectBytes"] == context * expected
    assert result["workerClosureBytes"] == closure * expected
    assert result.get("weakBox", 0) == result["register24"] == weak, (arm, result)


def schedule():
    scenario, codec, _ = WORKLOAD
    controls = list(COMPARISONS)
    for block in (1, 2):
        for pair in (1, 2, 3):
            offset = (block + pair - 2) % len(controls)
            turn = controls[offset:] + controls[:offset]
            flip = (block + pair) % 2 == 1
            for comparison in (turn[::-1] if flip else turn):
                placement = tuple(zip(COMPARISONS[comparison], ("base", "next")))
                meta = {"scenario": scenario, "codec": codec, "block": block, "pair": pair,
                        "comparison": comparison, "order": "RL" if flip else "LR"}
                yield meta, placement, placement[::-1] if flip else placement


def verify_s():
    observed = {}
    for line in (ROOT / "s-binding.sha256").read_text().splitlines():
        digest, path = line.split(maxsplit=1)
        assert path in S_BINDINGS and path not in observed
        assert sha256((ROOT / path).read_bytes()).hexdigest() == digest, path
        observed[path] = digest
    assert observed.keys() == S_BINDINGS
    return observed


def capture_stacks(measure, stacks, env, sites, witness):
    helper = runpy.run_path(str(ROOT / "allocation-helper.py"))
    standard = helper["traced_allocations"]
    capture = helper["allocation_sample"]
    capture.__globals__.update(ROOT=ROOT, parse=measure["parse"])

    def trace(arm, role, meta):
        def parse_history(history):
            result = stacks["attribute"](history, standard, sites)
            group = meta["comparison"]
            if group in ("AR", "RS", "AS") and (meta["block"], meta["pair"]) == (1, 1):
                name = f"{group}-{arm}-{role}.txt.gz"
                stacks["record_history"](witness / name, history)
                result["rawWitness"] = name
            return result

        capture.__globals__["traced_allocations"] = parse_history
        return capture(role, *WORKLOAD, env)

    return trace


def collect(tools, digests, scratch, out):
    measure, stacks, placement = tools
    reference = scratch / "reference"
    reference.mkdir()
    for arm, path in IMAGES.items():
        saved = reference / arm
        shutil.copy2(ROOT / "bin" / path, saved)
        assert placement["digest"](saved) == digests[arm]
    env = {key: value for key, value in os.environ.items() if not key.startswith("MallocStackLogging")}
    env.update(TMPDIR=scratch, LC_ALL="C", MallocStackLoggingNoCompact="1",
               MallocStackLoggingDirectory=scratch)
    witness = out / "raw"
    witness.mkdir()
    sites, published_sites, pids, rows = {}, set(), set(), []
    capture = capture_stacks(measure, stacks, env, sites, witness)
    try:
        with (out / "partial.jsonl").open("w") as journal:
            for meta, roles, launch in schedule():
                placement["replace"](reference, roles)
                arms = [dict(capture(arm, role, meta), arm=arm, imageSHA256=digests[arm]) for arm, role in launch]
                if meta["order"] == "RL":
                    arms.reverse()
                for arm in arms:
                    assert arm["pid"] not in pids
                    pids.add(arm["pid"])
                    arm["components"] = components(arm, sites)
                measure["ensure_equivalence"](*arms)
                row = {**meta, "left": arms[0], "right": arms[1]}
                rows.append(row)
                additions = {k: sites[k] for k in sorted(sites.keys() - published_sites)}
                published_sites.update(additions)
                journal.write(json.dumps({"row": row, "newSites": additions}, separators=(",", ":")) + "\n")
                journal.flush()
    finally:
        placement["replace"](reference, (("A", "base"), ("R", "next")))
    counts = Counter((row["comparison"], row["order"]) for row in rows)
    assert len(pids) == 72 and len(rows) == 36 and len(counts) == 12 and set(counts.values()) == {3}
    assert len(list(witness.iterdir())) == 6
    return rows, sites


def main():
    measure, stacks, placement = [runpy.run_path(str(ROOT / script)) for script in
                                  ("measure.py", "allocation-attribution.py", "qualify-r-hot-placement.py")]
    original, candidate = measure["verify_bindings"](), verify_s()
    images = {"A": original["bin/base"], "R": original["bin/next"], "S": candidate["bin/s"]}
    assert len(set(images.values())) == 3
    before = placement["runtime"]()
    out = ROOT / "r-s-cold-stacks"
    out.mkdir()
    (out / "runtime-before.json").write_text(json.dumps(before, indent=2) + "\n")
    with TemporaryDirectory(prefix="r-s-cold-stacks.", dir=ROOT) as scratch:
        rows, sites = collect((measure, stacks, placement), images, Path(scratch), out)
    after = placement["runtime"]()
    (out / "runtime-after.json").write_text(json.dumps(after, indent=2) + "\n")
    assert before == after and measure["verify_bindings"]() == original and verify_s() == candidate
    result = {"bindings": original, "sBindings": candidate, "runtime": before, "binariesSHA256": images,
              "sites": sites, "samples": rows, "fullWindowPerRefresh": measure["summary"](
                  rows, ("allocations", "requested_bytes"))}
    (out / "allocations.json").write_text(json.dumps(result, separators=(",", ":")) + "\n")
    for pair in rows:
        for arm in (pair["left"], pair["right"]):
            require_components(arm["components"], arm["arm"])
            if arm["arm"] != "S":
                assert arm["components"]["callbackSlab"] == (WORKLOAD[2] if arm["arm"] == "R" else 0)
    print("Verified 72 original single/Binary trace processes and the scoped weak-box change.")


if __name__ == "__main__":
    main()
