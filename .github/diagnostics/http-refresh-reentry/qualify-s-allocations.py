"""Acquire the nine exact S allocation leaves missing from the native archive."""

from collections import Counter
from hashlib import sha256
import json
import os
from pathlib import Path
import runpy
import tempfile


ROOT = Path(__file__).resolve().parent
REUSED_LEAF = ("single", "binary")
REUSED_ARTIFACT = "15138205812"
REUSED_SHA256 = "f4e8ae0f4cd7c431ab1078f00881d8a75bc019a59c001acd0ac98d09f4f28067"


def collect(measure, helper, env, journal):
    leaves = tuple(leaf for leaf in measure["FORMAL"] if leaf != REUSED_LEAF)
    assert REUSED_LEAF in measure["FORMAL"] and len(leaves) == 9
    paired = measure["paired_samples"]
    paired.__globals__["FORMAL"] = leaves
    capture = helper["allocation_sample"]
    capture.__globals__.update(ROOT=ROOT, parse=measure["parse"])
    pids = set()

    def observable(*args):
        row = capture(*args, env)
        assert row["pid"] not in pids
        pids.add(row["pid"])
        return row

    count = {"normal-off": 160, "normal": 160, "single": 24, "parallel-one": 24, "expiry": 24}
    rows = []
    for row in paired(observable, count, 3):
        journal.write(json.dumps(row, separators=(",", ":")) + "\n")
        journal.flush()
        rows.append(row)
    observed = Counter((r["scenario"], r["codec"], r["block"], r["comparison"]) for r in rows)
    expected = {(scenario, codec, block, comparison) for scenario, codec in leaves
                for block in (1, 2) for comparison in ("AA", "AB")}
    assert len(rows) == 108 and len(pids) == 216
    assert set(observed) == expected and set(observed.values()) == {3}
    return rows


def main():
    measure, helper = (runpy.run_path(str(ROOT / p)) for p in ("measure.py", "allocation-helper.py"))
    bindings = measure["verify_bindings"]()
    env = {k: v for k, v in os.environ.items() if not k.startswith("MallocStackLogging")}
    with tempfile.TemporaryDirectory(prefix="s-allocations.", dir=ROOT) as temporary:
        env.update(TMPDIR=temporary, LC_ALL="C", MallocStackLoggingNoCompact="1",
                   MallocStackLoggingDirectory=temporary)
        with (ROOT / "allocations.partial.jsonl").open("w") as journal:
            rows = collect(measure, helper, env, journal)
    assert measure["verify_bindings"]() == bindings
    output = {"bindings": bindings, "samples": rows,
              "metricsPerIterationOrBatch": measure["summary"](rows, ("allocations", "requested_bytes")),
              "reusedColdEvidence": {"artifact": REUSED_ARTIFACT, "sha256": REUSED_SHA256,
                                     "leaf": REUSED_LEAF},
              "allocationDriverSHA256": sha256(Path(__file__).read_bytes()).hexdigest()}
    (ROOT / "allocations.json").write_text(json.dumps(output, indent=2) + "\n")


if __name__ == "__main__":
    main()
