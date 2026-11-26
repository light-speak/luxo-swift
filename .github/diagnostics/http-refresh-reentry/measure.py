#!/usr/bin/env python3
import argparse
from hashlib import sha256
import json
import os
from pathlib import Path
import runpy
import statistics
import subprocess
import tempfile


ROOT = Path(__file__).resolve().parent
ITERATIONS = {"normal-off": 30_000, "normal": 30_000, "single": 8_000, "parallel-one": 3_000, "expiry": 3_000}
FORMAL = [(scenario, codec) for scenario in ITERATIONS for codec in ("json", "binary")]
COUNTS = ("iterations", "successes", "sends", "refreshes")
METRICS = ("cpu_us", "wall_ns")
DERIVED = {"Probe.swift", "measure.py", "base-sources.sha256", "next-sources.sha256", "toolchain.txt", "bin/base", "bin/next", "allocation-helper.py", "verify-timing.py"}
PRIOR = ROOT / "allocation-helper.py"


def verify_bindings():
    bindings = {}
    for line in (ROOT / "binding.sha256").read_text().splitlines():
        digest, path = line.split(maxsplit=1)
        assert path in DERIVED and path not in bindings, path
        assert sha256((ROOT / path).read_bytes()).hexdigest() == digest, path
        bindings[path] = digest
    assert bindings.keys() == DERIVED
    return bindings


def parse(line, role, scenario, codec, count):
    observed_scenario, observed_codec, observed_role, *values = line.strip().split(",")
    assert (observed_scenario, observed_codec, observed_role) == (scenario, codec, role), line
    assert len(values) == len(COUNTS + METRICS), line
    row = dict(zip(COUNTS + METRICS, map(int, values)))
    expected = {
        "normal-off": (count, count, 0, 0),
        "normal": (count, count, 0, 0),
        "single": (count, 2 * count, count, count),
        "parallel-one": (3 * count, 4 * count, count, count),
        "expiry": (3 * count, 6 * count, count, count),
    }
    success, sends, low_refreshes, high_refreshes = expected[scenario]
    assert row["iterations"] == count and row["successes"] == success and row["sends"] == sends, row
    assert low_refreshes <= row["refreshes"] <= high_refreshes, row
    assert all(row[key] > 0 for key in METRICS), row
    return {"scenario": scenario, "codec": codec, "role": role, **row}


def sample(role, scenario, codec, count, env):
    args = [str(ROOT / "bin" / role), scenario, codec, role, str(count), "timing"]
    output = subprocess.run(args, check=True, capture_output=True, text=True, timeout=35, env=env)
    assert not output.stderr, output.stderr
    return parse(output.stdout, role, scenario, codec, count)


def ensure_equivalence(left, right):
    assert all(left[n] == right[n] for n in COUNTS), (left, right)


def smoke(env):
    records = []
    for scenario, codec in FORMAL:
        count = 2 if scenario in ("expiry", "parallel-one") else 1
        pair = [sample(role, scenario, codec, count, env) for role in ("base", "next")]
        ensure_equivalence(*pair)
        records.extend({key: value for key, value in arm.items() if key not in METRICS} for arm in pair)
    return records


def paired_samples(sample_arm, count, sampling):
    comparisons = ("AA", "AB")
    for block in range(2):
        for scenario, codec in FORMAL:
            for index in range(sampling):
                flip = (block + index) % 2 == 1
                for compare in reversed(comparisons) if flip else comparisons:
                    roles = ("base", "base" if compare == "AA" else "next")
                    arms = [None, None]
                    for arm in (1, 0) if flip else (0, 1):
                        arms[arm] = sample_arm(roles[arm], scenario, codec, count[scenario])
                    ensure_equivalence(*arms)
                    yield dict(scenario=scenario, codec=codec, comparison=compare, order="BA" if flip else "AB",
                               block=block + 1, pair=index + 1, left=arms[0], right=arms[1])


def summary(rows, keys):
    groups = {}
    for row in rows:
        key = f"{row['scenario']}/{row['codec']}/{row['comparison']}/{row['block']}"
        groups.setdefault(key, []).append(row)
    result = {}
    for key, group in groups.items():
        result[key] = {}
        for field in keys:
            left = [r["left"][field] / r["left"]["iterations"] for r in group]
            right = [r["right"][field] / r["right"]["iterations"] for r in group]
            absolute = [r - l for l, r in zip(left, right)]
            relative = [100 * delta / base for delta, base in zip(absolute, left)]
            result[key][field] = dict(left=statistics.median(left), right=statistics.median(right),
                                      minDelta=min(absolute), maxDelta=max(absolute), medianDelta=statistics.median(absolute),
                                      medianPercent=statistics.median(relative))
    return result


def allocations(env):
    assert sha256(PRIOR.read_bytes()).hexdigest() == "5cc1d68bfb6cba41e09956330d1f0c269122b08f4a8fad677900888e1e39cdfd"
    helper = runpy.run_path(str(PRIOR))
    capture = helper["allocation_sample"]
    capture.__globals__.update(ROOT=ROOT, parse=parse)
    trace_env = {**env, "MallocStackLoggingNoCompact": "1", "MallocStackLoggingDirectory": env["TMPDIR"]}
    count = {"normal-off": 160, "normal": 160, "single": 24, "parallel-one": 24, "expiry": 24}
    return list(paired_samples(lambda *args: capture(*args, trace_env), count, 3))


def main():
    cli = argparse.ArgumentParser()
    cli.add_argument("mode", choices=("smoke", "timing", "allocations"))
    args = cli.parse_args()
    bindings = verify_bindings()
    env = {key: value for key, value in os.environ.items() if not key.startswith("MallocStackLogging")}
    os.umask(0o077)
    with tempfile.TemporaryDirectory(prefix=f"{args.mode}.", dir=ROOT) as workspace:
        env.update(TMPDIR=workspace, LC_ALL="C")
        if args.mode == "smoke":
            result = {"samples": smoke(env)}
        elif args.mode == "timing":
            result = timed_samples(env)
        else:
            rows = allocations(env)
            result = {"samples": rows, "metricsPerIterationOrBatch": summary(rows, ("allocations", "requested_bytes"))}
    assert verify_bindings() == bindings
    (ROOT / f"{args.mode}.json").write_text(json.dumps({"bindings": bindings, **result}, indent=2)+"\n")


def timed_samples(env):
    rows = []
    with (ROOT / "timing.partial.jsonl").open("w") as journal:
        for row in paired_samples(lambda *args: sample(*args, env), ITERATIONS, 10):
            rows.append(row)
            journal.write(json.dumps(row) + "\n")
            journal.flush()
            if row["pair"] == 10:
                print(row["block"], row["scenario"], row["codec"], row["comparison"], flush=True)
    assert len(rows) == 2 * len(FORMAL) * 10 * 2
    return {"samples": rows, "metricsPerIterationOrBatch": summary(rows, METRICS)}


if __name__ == "__main__":
    main()
