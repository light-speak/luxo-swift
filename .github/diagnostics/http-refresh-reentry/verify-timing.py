#!/usr/bin/env python3
"""Recompute paired release measurements without dropping a run or offsetting a cost."""

from collections import defaultdict
from hashlib import sha256
import json
from pathlib import Path
import statistics

ROOT = Path(__file__).resolve().parent
ITERATIONS = {"normal-off": 30_000, "normal": 30_000, "single": 8_000, "parallel-one": 3_000, "expiry": 3_000}
PAIR_KEYS = {(scenario, codec, comparison, block, pair)
             for scenario in ITERATIONS for codec in ("json", "binary")
             for comparison in ("AA", "AB") for block in (1, 2) for pair in range(1, 11)}


def verify_pairs(records):
    observed = set()
    results = defaultdict(list)
    for row in records:
        scenario, codec, comparison, block, pair = (row[k] for k in
            ("scenario", "codec", "comparison", "block", "pair"))
        key = (scenario, codec, comparison, block, pair)
        assert key in PAIR_KEYS and key not in observed, key
        observed.add(key)
        assert row["order"] == ("BA" if (block + pair) % 2 else "AB"), key
        count = ITERATIONS[scenario]
        if scenario in ("normal", "normal-off"):
            workload = (count, count, count, 0)
        elif scenario == "single":
            workload = (count, count, 2 * count, count)
        elif scenario == "parallel-one":
            workload = (count, 3 * count, 4 * count, count)
        else:
            workload = (count, 3 * count, 6 * count, count)
        left, right = row["left"], row["right"]
        expected_roles = ("base", "base" if comparison == "AA" else "next")
        for arm, role in zip((left, right), expected_roles):
            assert (arm["scenario"], arm["codec"], arm["role"]) == (scenario, codec, role), key
            assert tuple(arm[k] for k in ("iterations", "successes", "sends", "refreshes")) == workload, key
            assert arm["cpu_us"] > 0 and arm["wall_ns"] > 0, key
        results[(scenario, codec, comparison, block)].append({
            "cpu_us": (right["cpu_us"] - left["cpu_us"]) / count,
            "wall_us": (right["wall_ns"] - left["wall_ns"]) / (count * 1000),
        })
    assert observed == PAIR_KEYS, PAIR_KEYS - observed
    return results


def describe(samples, metric):
    deltas = [sample[metric] for sample in samples]
    positives = [delta for delta in deltas if delta > 0]
    return {"median": statistics.median(deltas), "min": min(deltas), "max": max(deltas),
            "positivePairs": len(positives), "maxPositive": max(positives, default=0)}


def main():
    source = ROOT / "timing.json"
    data = json.loads(source.read_text())
    for path, value in data["bindings"].items():
        assert sha256((ROOT / path).read_bytes()).hexdigest() == value, path
    groups = verify_pairs(data["samples"])
    summary = {"/".join(map(str, key)): {metric: describe(group, metric) for metric in ("cpu_us", "wall_us")}
               for key, group in sorted(groups.items())}
    receipt = {"timingSHA256": sha256(source.read_bytes()).hexdigest(), "verifiedPairs": len(PAIR_KEYS), "groups": summary}
    (ROOT / "timing-verified.json").write_text(json.dumps(receipt, indent=2) + "\n")
    for key, metrics in summary.items():
        cpu, wall = metrics["cpu_us"], metrics["wall_us"]
        print(f"{key}: CPU median {cpu['median']:+.3f}us, max positive {cpu['maxPositive']:.3f}us, "
              f"wall median {wall['median']:+.3f}us, max positive {wall['maxPositive']:.3f}us")


if __name__ == "__main__":
    main()
