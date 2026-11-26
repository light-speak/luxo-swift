"""Keep the published HTTP probe and collect only the outstanding A/R comparisons."""

import argparse
from collections import Counter
from hashlib import sha256
import json
import os
from pathlib import Path
import runpy
from tempfile import TemporaryDirectory

ROOT = Path(__file__).resolve().parent
HOT = [(scenario, codec) for scenario in ("normal-off", "normal") for codec in ("json", "binary")]
COLD = [("single", "json"), ("parallel-one", "binary"), ("expiry", "binary")]
PLANS = {
    "timing": {"original": {**dict.fromkeys(HOT, 30_000), ("expiry", "binary"): 3_000}},
    "allocation": {
        "original": {**dict.fromkeys(HOT, 160), **dict.fromkeys(COLD, 24)},
        "wide": dict.fromkeys(HOT, 320),
    },
}
COMPARISONS = {"AA": ("base", "base"), "RR": ("next", "next"), "AR": ("base", "next")}
PAIR_COUNTS = {"timing": 10, "allocation": 3}
WITNESS = {("normal-off", "binary"), *COLD}


def paired_samples(phase, capture, equivalent):
    comparisons = list(COMPARISONS)
    for block in (1, 2):
        for protocol, workload in PLANS[phase].items():
            for (scenario, codec), count in workload.items():
                for pair in range(1, PAIR_COUNTS[phase] + 1):
                    flip = (block + pair) % 2 == 1
                    shift = (block + pair - 2) % len(comparisons)
                    schedule = comparisons[shift:] + comparisons[:shift]
                    if flip:
                        schedule.reverse()
                    for comparison in schedule:
                        meta = dict(block=block, pair=pair, protocol=protocol, comparison=comparison,
                                    scenario=scenario, codec=codec, order="RA" if flip else "AR")
                        roles = COMPARISONS[comparison]
                        samples = [None, None]
                        for index in ((1, 0) if flip else (0, 1)):
                            samples[index] = capture(roles[index], scenario, codec, count, meta)
                        equivalent(*samples)
                        yield {**meta, "left": samples[0], "right": samples[1]}


def allocation_capture(measure, stack, env, sites):
    helper = runpy.run_path(str(ROOT / "allocation-helper.py"))
    standard = helper["traced_allocations"]
    probe = helper["allocation_sample"]
    probe.__globals__.update(ROOT=ROOT, parse=measure["parse"])
    witness = ROOT / "r-residual-raw"
    witness.mkdir()
    pids = set()
    env = {**env, "MallocStackLoggingNoCompact": "1", "MallocStackLoggingDirectory": env["TMPDIR"]}

    def capture(role, scenario, codec, count, meta):
        def parse_history(history):
            row = stack["attribute"](history, standard, sites)
            if (scenario, codec) in WITNESS and (
                meta["protocol"], meta["comparison"], meta["block"], meta["pair"]
            ) == ("original", "AR", 1, 1):
                name = f"{scenario}-{codec}-{role}.txt.gz"
                stack["record_history"](witness / name, history)
                row["rawWitness"] = name
            return row
        probe.__globals__["traced_allocations"] = parse_history
        result = probe(role, scenario, codec, count, env)
        assert result["pid"] not in pids, result["history_header"]
        pids.add(result["pid"])
        return result

    return capture


def collect(phase, measure, stack, env):
    sites = {}
    if phase == "timing":
        def capture(role, scenario, codec, count, _meta):
            return measure["sample"](role, scenario, codec, count, env)
    else:
        capture = allocation_capture(measure, stack, env, sites)
    rows = []
    written = set()
    samples = paired_samples(phase, capture, measure["ensure_equivalence"])
    with (ROOT / f"r-residual-{phase}.partial.jsonl").open("w") as journal:
        for row in samples:
            rows.append(row)
            additions = {site: sites[site] for site in sorted(sites.keys() - written)}
            written.update(additions)
            journal.write(json.dumps({"row": row, "newSites": additions}, separators=(",", ":")) + "\n")
            journal.flush()
            if row["pair"] == PAIR_COUNTS[phase]:
                print(row["block"], row["protocol"], row["scenario"], row["codec"], row["comparison"], flush=True)
    counts = Counter((row["protocol"], row["scenario"], row["codec"], row["comparison"], row["block"])
                     for row in rows)
    expected = {(protocol, scenario, codec, comparison, block)
                for protocol, workloads in PLANS[phase].items() for scenario, codec in workloads
                for comparison in COMPARISONS for block in (1, 2)}
    assert counts.keys() == expected and set(counts.values()) == {PAIR_COUNTS[phase]}
    if phase == "allocation":
        assert len(list((ROOT / "r-residual-raw").iterdir())) == 2 * len(WITNESS)
    summaries = {}
    for protocol in PLANS[phase]:
        matching = [row for row in rows if row["protocol"] == protocol]
        if phase == "timing":
            summaries[protocol] = measure["summary"](matching, ("cpu_us", "wall_ns"))
        else:
            summaries[protocol] = stack["summarize"](matching, sites)
    return {"samples": rows, "sites": sites, "summariesByProtocol": summaries}


def main():
    cli = argparse.ArgumentParser()
    cli.add_argument("phase", choices=PLANS)
    phase = cli.parse_args().phase
    measure = runpy.run_path(str(ROOT / "measure.py"))
    stack = runpy.run_path(str(ROOT / "allocation-attribution.py"))
    bindings = measure["verify_bindings"]()
    env = {key: value for key, value in os.environ.items() if not key.startswith("MallocStackLogging")}
    with TemporaryDirectory(prefix=f"r-residual-{phase}.", dir=ROOT) as scratch:
        env.update(TMPDIR=scratch, LC_ALL="C")
        result = collect(phase, measure, stack, env)
    assert measure["verify_bindings"]() == bindings
    result["bindings"] = bindings
    result["tools"] = {name: sha256((ROOT / name).read_bytes()).hexdigest()
                       for name in ("qualify-r-residual.py", "allocation-attribution.py")}
    (ROOT / f"r-residual-{phase}.json").write_text(json.dumps(result, separators=(",", ":")) + "\n")


if __name__ == "__main__":
    main()
