"""Run the original allocation sampler on exact S and its one-line scope ablation."""

import json
import os
from pathlib import Path
import runpy
import sys
from tempfile import TemporaryDirectory

ROOT = Path(__file__).resolve().parent
PRIOR = {
    "run": 45877234276,
    "artifact": 15146705454,
    "SHA256": "f6ec8af76480aa82f06763feaf2ae9a6737dfa1b6048a8cb87183a5742eeac13",
    "product": "2a8108bbe2692c349069d71b2f5eb2f9a501c171",
}
ARM_TREES = {
    "A": "e86fd9264f0d875ca10967a4b56124c8dbc18e79",
    "S": "e457fb715025330006e7f4194c92a7e6f457f6e0",
}
MANIFESTS = {
    "base-sources.sha256": "d7d481636279149af83d6c04e7450e0d2297f53fdc5e333e273fd14d722bb311",
    "next-sources.sha256": "5239e6b2f2a32a672a43e790bfad63b8b3a1a7a9711e28aff0d6a1b56d47b8e1",
}
SLAB_FIELDS = ("total1016", "probeMain1016", "registerRefresh1016", "other1016")
COUNTS = {"iterations": 24, "successes": 72, "sends": 96, "refreshes": 24}


def read_driver(name):
    return runpy.run_path(str(ROOT / name))


def classify(samples):
    assert set(samples) == {"joint", "split"}
    deltas = {}
    for layout, rows in samples.items():
        deltas[layout] = group = {key: [] for key in ("AA", "SS", "AS")}
        for row in rows:
            assert all({key: row[side][key] for key in COUNTS} == COUNTS for side in ("left", "right"))
            group[row["comparison"]].append({
                field: row["right"]["slabs"][field] - row["left"]["slabs"][field] for field in SLAB_FIELDS
            })
        assert all(len(group[key]) == 6 for key in group)
    controls = all(pair[field] == 0
                   for layout in deltas.values() for control in ("AA", "SS")
                   for pair in layout[control] for field in SLAB_FIELDS[:2])
    if not controls:
        return "same-image slab controls varied", deltas, False
    if all(pair["total1016"] == pair["probeMain1016"] == -24
           for layout in deltas.values() for pair in layout["AS"]):
        return "one 1016-byte Probe.main slab per refresh removed by scope ablation in both layouts", deltas, True
    return "scope ablation did not consistently remove that slab in both layouts", deltas, True


def main():
    out = Path(sys.argv[1]).resolve(strict=True)
    driver = read_driver("qualify-s-parallel-followup.py")
    measure = read_driver("measure.py")
    placement = read_driver("qualify-r-hot-placement.py")
    helper = read_driver("allocation-helper.py")
    attributor = read_driver("allocation-attribution.py")
    binding = measure["verify_bindings"]()
    assert all(binding[name] == digest for name, digest in MANIFESTS.items())
    split = driver["verify_split"]()
    images = {layout: {arm: hashes[prefix + role] for arm, role in driver["STOCK"]}
              for layout, hashes, prefix in (("joint", binding, "bin/"), ("split", split, "split/bin/"))}
    runtime = placement["runtime"]()
    # The original driver uses A/S labels for the two binary slots. Keep the original schedule.
    driver["allocation"].__globals__["match_status"] = lambda rows: classify(rows)[0]
    with TemporaryDirectory(prefix="scope-tracing.", dir=ROOT) as temporary:
        scratch = Path(temporary)
        env = driver["isolate_environment"](scratch)
        env.update(MallocStackLoggingNoCompact="1", MallocStackLoggingDirectory=str(scratch))
        result = driver["allocation"](measure, placement, helper, attributor, out, scratch, env, images)
    verdict, deltas, controls = classify(result["samples"])
    assert driver["verify_split"]() == split
    assert measure["verify_bindings"]() == binding and placement["runtime"]() == runtime
    result.update(prior=PRIOR, runtime=runtime, roleLabels={"A": "intact S", "S": "S without callback scope"},
                  armTrees=ARM_TREES, imageSHA256=images, bindings=binding, splitBindings=split,
                  expectedOperationCounts=COUNTS, slabDeltas=deltas, controlsStable=controls, verdict=verdict)
    (out / "scope-allocations.json").write_text(json.dumps(result, separators=(",", ":")) + "\n")
    print(verdict, flush=True)
    return 0 if controls else 1


if __name__ == "__main__":
    raise SystemExit(main())
