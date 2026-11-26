"""Attribute the remaining exact A/S refresh allocations on one native worker."""

from collections import Counter
from hashlib import sha256
import json
import os
from pathlib import Path
import runpy
import shutil
from tempfile import TemporaryDirectory

ROOT = Path(__file__).resolve().parent
WORKLOADS = {
    ("normal-off", "json"): 160,
    ("single", "json"): 24,
    ("parallel-one", "binary"): 24,
    ("expiry", "json"): 24,
}
COMPARISONS = ("AA", "SS", "AS")
STOCK = (("A", "base"), ("S", "next"))
PRIOR = {
    "qualification": "45866208304",
    "qualificationArtifact": "15142395987",
    "qualificationSHA256": "b563b8f2536dd3649648d50a71a914bc3cf1f9f9c58309fbf8b6222b9f69e65b",
    "singleBinaryArtifact": "15138205812",
    "singleBinarySHA256": "f4e8ae0f4cd7c431ab1078f00881d8a75bc019a59c001acd0ac98d09f4f28067",
}


def schedule():
    for block in (1, 2):
        for scenario, codec in WORKLOADS:
            for pair in (1, 2, 3):
                offset = (block + pair - 2) % len(COMPARISONS)
                order = COMPARISONS[offset:] + COMPARISONS[:offset]
                flip = (block + pair) % 2 == 1
                for comparison in order[::-1] if flip else order:
                    placement = tuple(zip(comparison, ("base", "next")))
                    yield dict(scenario=scenario, codec=codec, block=block, pair=pair,
                               comparison=comparison, order="RL" if flip else "LR"), placement


def capture_arm(capture, original, attribution, sites, witness, env, meta, image, role):
    scenario, codec = meta["scenario"], meta["codec"]

    def parse_history(history):
        result = attribution["attribute"](history, original, sites)
        if (meta["comparison"], meta["block"], meta["pair"]) == ("AS", 1, 1):
            name = f"{scenario}-{codec}-{image}-{role}.txt.gz"
            attribution["record_history"](witness / name, history)
            result["rawWitness"] = name
        return result

    capture.__globals__["traced_allocations"] = parse_history
    return capture(role, scenario, codec, WORKLOADS[scenario, codec], env)


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


def collect(tools, images, scratch, out):
    measure, helper, attribution, placement, cold = tools
    capture = helper["allocation_sample"]
    capture.__globals__.update(ROOT=ROOT, parse=measure["parse"])
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
            for meta, roles in schedule():
                placement["replace"](reference, roles)
                launch = roles[::-1] if meta["order"] == "RL" else roles
                arms = {}
                for image, role in launch:
                    arm = capture_arm(capture, original, attribution, sites, witness, env, meta, image, role)
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

    orders = Counter((r["scenario"], r["codec"], r["comparison"], r["order"]) for r in rows)
    assert len(orders) == 4 * 3 * 2 and set(orders.values()) == {3}
    assert len(rows) == 72 and len(pids) == 144 and len(list(witness.iterdir())) == 8
    return rows, sites


def main():
    tools = tuple(runpy.run_path(str(ROOT / file)) for file in (
        "measure.py", "allocation-helper.py", "allocation-attribution.py",
        "qualify-r-hot-placement.py", "qualify-r-s-cold-stacks.py"))
    measure, _, attribution, placement, _ = tools
    bindings = measure["verify_bindings"]()
    images = {"A": bindings["bin/base"], "S": bindings["bin/next"]}
    assert images["A"] != images["S"]
    runtime = placement["runtime"]()
    out = ROOT / "s-cold-attribution"
    out.mkdir()
    (out / "runtime-before.json").write_text(json.dumps(runtime, indent=2) + "\n")
    with TemporaryDirectory(prefix="s-cold-attribution.", dir=ROOT) as scratch:
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
    (out / "allocations.json").write_text(json.dumps(result, separators=(",", ":")) + "\n")
    print("Captured 144 exact A/S trace processes, with both same-image controls.")
    if unclassified:
        print("Unclassified direct allocation shapes:", json.dumps(unclassified, sort_keys=True))


if __name__ == "__main__":
    main()
