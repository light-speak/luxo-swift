"""Attribute the remaining exact A/S refresh allocations on one native worker."""

from collections import Counter
from hashlib import sha256
import json
import os
from pathlib import Path
import runpy
import shutil
import sys
from tempfile import TemporaryDirectory

ROOT = Path(__file__).resolve().parent
WORKLOADS = {
    ("normal-off", "json"): 160,
    ("single", "json"): 24,
    ("parallel-one", "binary"): 24,
    ("expiry", "json"): 24,
}
COMPARISONS = ("AA", "SS", "AS")
PLACEMENT_COMPARISONS = (*COMPARISONS, "SA")
STOCK = (("A", "base"), ("S", "next"))
PRIOR = {
    "qualification": "45866208304",
    "qualificationArtifact": "15142395987",
    "qualificationSHA256": "b563b8f2536dd3649648d50a71a914bc3cf1f9f9c58309fbf8b6222b9f69e65b",
    "singleBinaryArtifact": "15138205812",
    "singleBinarySHA256": "f4e8ae0f4cd7c431ab1078f00881d8a75bc019a59c001acd0ac98d09f4f28067",
}


def schedule(workloads=WORKLOADS, comparisons=COMPARISONS):
    for block in (1, 2):
        for scenario, codec in workloads:
            for pair in (1, 2, 3):
                offset = (block + pair - 2) % len(comparisons)
                order = comparisons[offset:] + comparisons[:offset]
                flip = (block + pair) % 2 == 1
                for comparison in order[::-1] if flip else order:
                    placement = tuple(zip(comparison, ("base", "next")))
                    yield dict(scenario=scenario, codec=codec, block=block, pair=pair,
                               comparison=comparison, order="RL" if flip else "LR"), placement


def capture_arm(capture, original, attribution, sites, witness, env, meta, image, role, iterations):
    scenario, codec = meta["scenario"], meta["codec"]

    def parse_history(history):
        result = attribution["attribute"](history, original, sites)
        if meta["comparison"] in ("AS", "SA") and (meta["block"], meta["pair"]) == (1, 1):
            name = f"{scenario}-{codec}-{image}-{role}.txt.gz"
            attribution["record_history"](witness / name, history)
            result["rawWitness"] = name
        return result

    capture.__globals__["traced_allocations"] = parse_history
    return capture(role, scenario, codec, iterations, env)


def classify(arm, cold, sites):
    summary = cold["components"](arm, sites)
    try:
        cold["require_components"](summary, arm["arm"], arm["refreshes"])
    except AssertionError:
        # Keep structural measurements even if a new linker shape lacks symbol evidence.
        complete = False
    else:
        complete = True
    return dict(summary, directWitnessComplete=complete)


def collect(tools, images, scratch, out, workloads=WORKLOADS, comparisons=COMPARISONS):
    measure, helper, attribution, placement, cold = tools
    capture = helper["allocation_sample"]
    capture.__globals__.update(ROOT=ROOT, parse=measure["parse"])
    placement["replace"].__globals__["ROOT"] = ROOT
    original = helper["traced_allocations"]
    reference = scratch / "reference"
    reference.mkdir()
    for arm, role in STOCK:
        shutil.copy2(ROOT / "bin" / role, reference / arm)
        assert placement["digest"](reference / arm) == images[arm]
    env = {key: value for key, value in os.environ.items() if not key.startswith("MallocStackLogging")}
    env.update(TMPDIR=scratch, LC_ALL="C", MallocStackLoggingNoCompact="1", MallocStackLoggingDirectory=scratch)
    witness = out / "raw"
    witness.mkdir()
    rows, sites, pids, written = [], {}, set(), set()
    try:
        with (out / "partial.jsonl").open("w") as journal:
            for meta, roles in schedule(workloads, comparisons):
                placement["replace"](reference, roles)
                launch = roles[::-1] if meta["order"] == "RL" else roles
                arms = {}
                for image, role in launch:
                    arm = capture_arm(capture, original, attribution, sites, witness, env, meta, image, role,
                                      workloads[meta["scenario"], meta["codec"]])
                    assert arm["pid"] not in pids
                    pids.add(arm["pid"])
                    arm.update(arm=image, imageSHA256=images[image])
                    arm["components"] = classify(arm, cold, sites)
                    arms[role] = arm
                measure["ensure_equivalence"](arms["base"], arms["next"])
                row = dict(meta, left=arms["base"], right=arms["next"])
                rows.append(row)
                additions = {key: sites[key] for key in sorted(sites.keys() - written)}
                written.update(additions)
                journal.write(json.dumps({"row": row, "newSites": additions}, separators=(",", ":")) + "\n")
                journal.flush()
                if meta["pair"] == 3:
                    print(meta["block"], meta["scenario"], meta["codec"], meta["comparison"], flush=True)
    finally:
        placement["replace"](reference, STOCK)

    plan = list(schedule(workloads, comparisons))
    assert len(rows) == len(plan) and len(pids) == 2 * len(plan)
    assert all(all(row[key] == value for key, value in meta.items()) for row, (meta, _) in zip(rows, plan))
    assert len(list(witness.iterdir())) == len(workloads) * (4 if "SA" in comparisons else 2)
    return rows, sites


def main():
    placement_only = len(sys.argv) == 3 and sys.argv[1] == "--normal-off"
    assert placement_only or len(sys.argv) == 1
    tools = tuple(runpy.run_path(str(ROOT / file)) for file in (
        "measure.py", "allocation-helper.py", "allocation-attribution.py",
        "qualify-r-hot-placement.py", "qualify-r-s-cold-stacks.py"))
    measure, _, attribution, placement, _ = tools
    bindings = measure["verify_bindings"]()
    images = {"A": bindings["bin/base"], "S": bindings["bin/next"]}
    assert images["A"] != images["S"]
    runtime = placement["runtime"]()
    out = Path(sys.argv[2]).resolve(strict=True) if placement_only else ROOT / "s-cold-attribution"
    if placement_only:
        assert all(bindings[name] == digest for name, digest in {
            "base-sources.sha256": "a62dfb5670bc942eb82e9bf9db26a0befa819d3c44a7e044b1d02c80a43f4739",
            "next-sources.sha256": "d7d481636279149af83d6c04e7450e0d2297f53fdc5e333e273fd14d722bb311",
        }.items())
        for arm, role in STOCK:
            placement["record_image"](role, images[arm], out)
    else:
        out.mkdir()
    (out / "runtime-before.json").write_text(json.dumps(runtime, indent=2) + "\n")
    with TemporaryDirectory(prefix="s-cold-attribution.", dir=ROOT) as scratch:
        if placement_only:
            rows, sites = collect(tools, images, Path(scratch), out,
                                  {("normal-off", "json"): 160}, PLACEMENT_COMPARISONS)
        else:
            rows, sites = collect(tools, images, Path(scratch), out)
    after = placement["runtime"]()
    (out / "runtime-after.json").write_text(json.dumps(after, indent=2) + "\n")
    assert after == runtime and measure["verify_bindings"]() == bindings
    unclassified = Counter(f"{row['scenario']}/{row['codec']}/{arm['arm']}"
                           for row in rows for arm in (row["left"], row["right"])
                           if not arm["components"]["directWitnessComplete"])
    result = dict(prior=PRIOR, bindings=bindings, runtime=runtime, imageSHA256=images,
                  unclassifiedDirectProcesses=unclassified,
                  driverSHA256=sha256(Path(__file__).read_bytes()).hexdigest(),
                  sites=sites, samples=rows, units=["allocations", "requested bytes"],
                  deltasPerOperationOrBatch=attribution["summarize"](rows, sites),
                  fullWindow=measure["summary"](rows, ("allocations", "requested_bytes")))
    if placement_only:
        assert not unclassified and all(arm["refreshes"] == 0 for row in rows for arm in (row["left"], row["right"]))
        result["dispatchWorker4096"] = dispatch_worker_deltas(rows, sites)
    (out / "allocations.json").write_text(json.dumps(result, separators=(",", ":")) + "\n")
    if placement_only:
        assert len(rows) == 24
        (out / "placement-count.txt").write_text(f"no_refresh_placement_pairs={len(rows)}\n")
    print(f"Captured {2 * len(rows)} traced processes, with both same-image controls.")
    if unclassified:
        print("Unclassified direct allocation shapes:", json.dumps(unclassified, sort_keys=True))


def dispatch_worker_deltas(rows, sites):
    worker_sites = {
        key for key, site in sites.items()
        if any("AutoreleasePoolPage::autoreleaseNoPage" in frame for frame in site["frames"])
        and any("_dispatch_last_resort_autorelease_pool_push" in frame for frame in site["frames"])
    }
    result = []
    for row in rows:
        left, right = [
            sum(count for signature, histogram in row[side]["stackCountsBySize"].items()
                if signature in worker_sites for size, count in histogram.items() if int(size) == 4096)
            for side in ("left", "right")]
        # The crossed placement runs S on the left; express both cross-image differences as S minus A.
        pages = left - right if row["comparison"] == "SA" else right - left
        result.append({key: row[key] for key in ("block", "pair", "order", "comparison")}
                      | dict(pagesLeft=left, pagesRight=right, pagesSigned=pages, bytesSigned=4096 * pages))
    return result


if __name__ == "__main__":
    main()
