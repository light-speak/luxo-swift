"""Replay the original Swift Binary timing leaf and isolate probe WMO in a separate allocation lane."""

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
SCENARIO, CODEC = "parallel-one", "binary"
TIMED, TRACED = 3000, 24
COMPARISONS = ("AA", "SS", "AS")
ORIGINAL_ROLES = {"AA": ("base", "base"), "SS": ("next", "next"), "AS": ("base", "next")}
STOCK = (("A", "base"), ("S", "next"))
LAYOUTS = ("joint", "split")
PRIOR = {
    "timingRun": 45866208304,
    "timingArtifact": 15142395987,
    "timingSHA256": "b563b8f2536dd3649648d50a71a914bc3cf1f9f9c58309fbf8b6222b9f69e65b",
    "attributionRun": 45871190819,
    "attributionArtifact": 15143083339,
    "attributionSHA256": "99d025b6ee961ca3c602e3120858b4fbf9d01a7e8ce41d0ad87135b637dde84f",
    "base": "d6578969bcef258141c7c99cb6cface30a22a0e2",
    "product": "2a8108bbe2692c349069d71b2f5eb2f9a501c171",
    "clientTree": "a76077acde23e0da5936e20c3b20acbd6024ae50",
}
SOURCE_MANIFESTS = {
    "base-sources.sha256": "a62dfb5670bc942eb82e9bf9db26a0befa819d3c44a7e044b1d02c80a43f4739",
    "next-sources.sha256": "d7d481636279149af83d6c04e7450e0d2297f53fdc5e333e273fd14d722bb311",
}
SPLIT_PROBE = "9fe213ad1f705b5287a33f025099af4c9b44b49d00ee69450cbdf597a26b1a01"


def digest(path):
    return sha256(path.read_bytes()).hexdigest()


def schedule(pair_count):
    for block in (1, 2):
        for pair in range(1, pair_count + 1):
            reverse = (block + pair) % 2 == 1
            for comparison in COMPARISONS[::-1] if reverse else COMPARISONS:
                yield dict(scenario=SCENARIO, codec=CODEC, comparison=comparison,
                           block=block, pair=pair, order="RL" if reverse else "LR")


def validate_rows(rows, pair_count):
    assert [{k: row[k] for k in meta} for row, meta in zip(rows, schedule(pair_count))] == list(schedule(pair_count))
    assert len(rows) == 2 * pair_count * len(COMPARISONS)
    assert len({arm["pid"] for row in rows for arm in (row["left"], row["right"])}) == 2 * len(rows)
    by_order = Counter((row["block"], row["comparison"], row["order"]) for row in rows)
    if pair_count == 10:
        assert len(by_order) == 12 and set(by_order.values()) == {5}
    else:
        assert all(sum(by_order[block, comparison, order] for block in (1, 2)) == pair_count
                   for comparison in COMPARISONS for order in ("LR", "RL"))


def verify_source(measure):
    bindings = measure["verify_bindings"]()
    assert all(bindings[name] == expected for name, expected in SOURCE_MANIFESTS.items())
    return bindings


def isolate_environment(scratch):
    env = {k: v for k, v in os.environ.items()
           if not k.startswith(("MallocStackLogging", "DYLD_PRINT_"))}
    return dict(env, TMPDIR=str(scratch), LC_ALL="C")


def journal_record(journal, data):
    journal.write(json.dumps(data, separators=(",", ":")) + "\n")
    journal.flush()


def timing(measure, placement, out, env, bindings):
    sample = placement["sample"]
    sample.__globals__["WORKLOAD"] = (SCENARIO, CODEC, TIMED)
    sample.__globals__["ROOT"] = ROOT
    smoke = [measure["sample"](role, SCENARIO, CODEC, 2, env) for _, role in STOCK]
    measure["ensure_equivalence"](*smoke)
    images = {arm: bindings["bin/" + role] for arm, role in STOCK}
    rows = []
    with (out / "parallel-timing.partial.jsonl").open("w") as journal:
        for meta in schedule(10):
            placement_roles = list(zip(meta["comparison"], ORIGINAL_ROLES[meta["comparison"]]))
            launch = placement_roles[::-1] if meta["order"] == "RL" else placement_roles
            values = [dict(sample(arm, role, measure["parse"], env), imageSHA256=images[arm]) for arm, role in launch]
            left, right = values[::-1] if meta["order"] == "RL" else values
            measure["ensure_equivalence"](left, right)
            rows.append(dict(meta, left=left, right=right))
            journal_record(journal, rows[-1])
    validate_rows(rows, 10)
    return dict(samples=rows, smoke=smoke, originalRoles=ORIGINAL_ROLES, imageSHA256=images,
                metricsPerBatch=measure["summary"](rows, ("cpu_us", "wall_ns")))


def verify_split():
    paths = {path: digest(ROOT / path) for path in (
        "split/Probe.swift", "split/bin/base", "split/bin/next",
        "split/base/LuxoClient.swiftmodule", "split/base/libLuxoClient.a",
        "split/next/LuxoClient.swiftmodule", "split/next/libLuxoClient.a")}
    assert paths["split/Probe.swift"] == SPLIT_PROBE
    assert (ROOT / "split/Probe.swift").read_bytes() == b"import LuxoClient\n" + (ROOT / "Probe.swift").read_bytes()
    return paths


def slabs(histogram, sites):
    count = dict(total1016=0, probeMain1016=0, registerRefresh1016=0, other1016=0)
    for sig, sizes in histogram.items():
        frames = sites[sig]["frames"]
        n = sizes.get(1016, 0)
        if not n or not any("swift::StackAllocator<" in f for f in frames):
            continue
        count["total1016"] += n
        if len(frames) > 3 and "partial apply for closure #1 in static Probe.main()" in frames[3]:
            count["probeMain1016"] += n
        elif any("HTTPTransport.registerRefresh" in f for f in frames):
            count["registerRefresh1016"] += n
        else:
            count["other1016"] += n
    return count


def capture_stacks(capture, original, attributor, sites, target, witness, env, meta, arm, role):
    def parse_history(history):
        row = attributor["attribute"](history, original, sites)
        if (meta["comparison"], meta["block"], meta["pair"]) == ("AS", 1, 1):
            name = f"{meta['layout']}-{arm}-{role}.txt.gz"
            attributor["record_history"](witness / name, history)
            row["rawWitness"] = name
        return row

    capture.__globals__.update(ROOT=target, traced_allocations=parse_history)
    row = capture(role, SCENARIO, CODEC, TRACED, env)
    return dict(row, arm=arm, slabs=slabs(row["stackCountsBySize"], sites))


def match_status(by_layout):
    def invariant(layout, comparison, field, expected):
        return all(r["right"]["slabs"][field] - r["left"]["slabs"][field] == expected
                   for r in by_layout[layout] if r["comparison"] == comparison)

    if not all(invariant(layout, label, field, 0)
               for layout in LAYOUTS for label in ("AA", "SS") for field in ("total1016", "probeMain1016")):
        return "control varies; do not assign a fixed slab"
    if not all(invariant("joint", "AS", field, TRACED) for field in ("total1016", "probeMain1016")):
        return "prior joint-WMO witness was not reproduced"
    if all(invariant("split", "AS", field, 0) for field in ("total1016", "probeMain1016")):
        return "excess slab absent in split-module build"
    if invariant("split", "AS", "total1016", TRACED) and invariant("split", "AS", "probeMain1016", 0):
        return "excess slab persists with a different stack"
    return "excess slab needs per-stack review in the split build"


def allocation(measure, placement, helper, attributor, out, scratch, env, images):
    capture = helper["allocation_sample"]
    capture.__globals__["parse"] = measure["parse"]
    original = helper["traced_allocations"]
    targets = {"joint": ROOT, "split": ROOT / "split"}
    witness = out / "parallel-raw"
    witness.mkdir()
    reference = {}
    for layout, target in targets.items():
        reference[layout] = scratch / layout
        reference[layout].mkdir()
        for arm, role in STOCK:
            shutil.copy2(target / "bin" / role, reference[layout] / arm)
            assert digest(reference[layout] / arm) == images[layout][arm]
        smoke = [measure["parse"](
            placement["command"](str(target / "bin" / role), SCENARIO, CODEC, role, "2", "timing", env=env),
            role, SCENARIO, CODEC, 2) for _, role in STOCK]
        measure["ensure_equivalence"](*smoke)
        (out / f"parallel-{layout}-smoke.json").write_text(json.dumps(smoke, indent=2) + "\n")

    sites, written = {}, set()
    samples = {layout: [] for layout in LAYOUTS}

    def place(layout, roles):
        replace = placement["replace"]
        replace.__globals__["ROOT"] = targets[layout]
        replace(reference[layout], roles)

    try:
        with (out / "parallel-allocations.partial.jsonl").open("w") as journal:
            for meta in schedule(3):
                layout_order = LAYOUTS[::-1] if meta["order"] == "RL" else LAYOUTS
                for layout in layout_order:
                    scoped = dict(meta, layout=layout)
                    roles = tuple(zip(meta["comparison"], ("base", "next")))
                    place(layout, roles)
                    launch = roles[::-1] if meta["order"] == "RL" else roles
                    rows = {}
                    for arm, role in launch:
                        row = capture_stacks(capture, original, attributor, sites, targets[layout],
                                             witness, env, scoped, arm, role)
                        rows[role] = dict(row, imageSHA256=images[layout][arm])
                    measure["ensure_equivalence"](rows["base"], rows["next"])
                    sample = dict(scoped, left=rows["base"], right=rows["next"])
                    samples[layout].append(sample)
                    additions = {key: sites[key] for key in sorted(sites.keys() - written)}
                    written.update(additions)
                    journal_record(journal, dict(row=sample, newSites=additions))
    finally:
        for layout in LAYOUTS:
            place(layout, STOCK)

    for rows in samples.values():
        validate_rows(rows, 3)
    assert len({arm["pid"] for rows in samples.values() for row in rows
                for arm in (row["left"], row["right"])}) == 72
    assert len(list(witness.iterdir())) == 4
    return dict(samples=samples, sites=sites, verdict=match_status(samples),
                fullWindow={layout: measure["summary"](rows, ("allocations", "requested_bytes"))
                            for layout, rows in samples.items()})


def main():
    mode, destination = sys.argv[1:]
    assert mode in ("timing", "allocations")
    out = Path(destination).resolve(strict=True)
    measure, placement = (runpy.run_path(str(ROOT / name)) for name in (
        "measure.py", "qualify-r-hot-placement.py"))
    binding = verify_source(measure)
    runtime = placement["runtime"]()
    joint_images = {arm: binding["bin/" + role] for arm, role in STOCK}
    with TemporaryDirectory(prefix=f"parallel-{mode}.", dir=ROOT) as tmp:
        scratch = Path(tmp)
        env = isolate_environment(scratch)
        if mode == "timing":
            result = timing(measure, placement, out, env, binding)
        else:
            earlier = json.loads((out / "parallel-timing.json").read_text())
            before = earlier["runtime"]
            assert {k: v for k, v in runtime.items() if k != "samplerPID"} == {
                k: v for k, v in before.items() if k != "samplerPID"}
            assert earlier["bindings"] == binding and earlier["prior"] == PRIOR
            split = verify_split()
            images = {"joint": joint_images, "split": {arm: split["split/bin/" + role] for arm, role in STOCK}}
            helper, attributor = (runpy.run_path(str(ROOT / name)) for name in (
                "allocation-helper.py", "allocation-attribution.py"))
            env.update(MallocStackLoggingNoCompact="1", MallocStackLoggingDirectory=str(scratch))
            result = allocation(measure, placement, helper, attributor, out, scratch, env, images)
            assert verify_split() == split
            result.update(splitBindings=split, imageSHA256=images)
    assert verify_source(measure) == binding and placement["runtime"]() == runtime
    result.update(prior=PRIOR, bindings=binding, runtime=runtime, driverSHA256=digest(Path(__file__)))
    (out / f"parallel-{mode}.json").write_text(json.dumps(result, separators=(",", ":")) + "\n")
    print(f"parallel-one/binary {mode} evidence written", flush=True)


if __name__ == "__main__":
    main()
