"""Compare exact A/R HTTP success timings with both executable placements."""

from collections import Counter
from hashlib import sha256
import json
import os
from pathlib import Path
import re
import runpy
import shutil
import subprocess
from tempfile import TemporaryDirectory

ROOT = Path(__file__).resolve().parent
WORKLOAD = ("normal-off", "json", 30_000)
PLACEMENTS = {
    "AA-path": (("A", "base"), ("A", "next")),
    "RR-path": (("R", "base"), ("R", "next")),
    "AR-stock": (("A", "base"), ("R", "next")),
    "AR-swapped": (("A", "next"), ("R", "base")),
}
STOCK = {"A": "base", "R": "next"}
HOT_SYMBOL = re.compile(r"HTTPTransport|HTTPCallDeadline|ProbeBackend|5Probe33_|JSONResponse|JSONEnvelope")


def schedule():
    scenario, codec, _ = WORKLOAD
    for block in (1, 2):
        choices = list(PLACEMENTS) if block == 1 else list(reversed(PLACEMENTS))
        for comparison in choices:
            roles = PLACEMENTS[comparison]
            for pair in range(1, 11):
                flip = (block + pair) % 2 == 1
                row = dict(block=block, pair=pair, scenario=scenario, codec=codec,
                           comparison=comparison, order="RL" if flip else "LR")
                yield row, roles[::-1] if flip else roles


def digest(path):
    return sha256(path.read_bytes()).hexdigest()


def replace(stock, placement):
    for arm, role in placement:
        slot = ROOT / "bin" / role
        pending = slot.with_suffix(".new")
        shutil.copy2(stock / arm, pending)
        pending.replace(slot)
        assert digest(slot) == digest(stock / arm)


def command(*args, **options):
    return subprocess.run(args, check=True, text=True, capture_output=True, timeout=20, **options).stdout


def runtime():
    result = {"node": os.uname().nodename, "samplerPID": os.getpid()}
    for key in ("kern.boottime", "kern.bootsessionuuid", "kern.osversion"):
        completed = subprocess.run(("/usr/sbin/sysctl", "-n", key), capture_output=True, text=True, timeout=10)
        result[key] = completed.stdout.strip() if completed.returncode == 0 else "unavailable"
    assert result["kern.boottime"] != "unavailable" and result["kern.boottime"].strip()
    return result


def record_image(role, stock_digest, directory):
    binary = ROOT / "bin" / role
    assert digest(binary) == stock_digest
    loads = command("xcrun", "otool", "-l", str(binary))
    text_addr = re.search(r"\bsegname __TEXT\s+vmaddr (0x[0-9a-fA-F]+)", loads)
    assert text_addr and "LC_UUID" in loads and "LC_BUILD_VERSION" in loads, role
    start = int(text_addr[1], 16)
    offsets = []
    for line in command("xcrun", "nm", "-n", str(binary)).splitlines():
        fields = line.split(maxsplit=2)
        if len(fields) == 3 and fields[1] in ("t", "T") and HOT_SYMBOL.search(fields[2]):
            offsets.append([int(fields[0], 16) - start, fields[2]])
    assert any("callRequest" in symbol for _, symbol in offsets) and any("performRequest" in symbol for _, symbol in offsets)
    assert all(offset >= 0 for offset, _ in offsets)
    (directory / f"{role}-mach-o-load.txt").write_text(loads)
    (directory / f"{role}-linked-images.txt").write_text(command("xcrun", "otool", "-L", str(binary)))
    image = {"sha256": stock_digest, "textVMAddr": start, "offsetsFromTextVMAddr": offsets}
    (directory / f"{role}-hot-symbols.json").write_text(json.dumps(image, separators=(",", ":")) + "\n")


def sample(arm, role, parse, env):
    scenario, codec, count = WORKLOAD
    binary = ROOT / "bin" / role
    args = [str(binary), scenario, codec, role, str(count), "timing"]
    with subprocess.Popen(args, env=env, stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True) as target:
        try:
            stdout, stderr = target.communicate(timeout=35)
        finally:
            if target.poll() is None:
                target.kill()
                target.wait()
        assert target.returncode == 0 and not stderr, (args, target.returncode, stderr)
    row = parse(stdout, role, scenario, codec, count)
    return {**row, "arm": arm, "pid": target.pid}


def timings(measure, bindings, scratch):
    reference = scratch / "reference"
    reference.mkdir()
    for arm, role in STOCK.items():
        shutil.copy2(ROOT / "bin" / role, reference / arm)
        assert digest(reference / arm) == bindings[f"bin/{role}"]

    env = {key: value for key, value in os.environ.items() if not key.startswith(("MallocStackLogging", "DYLD_PRINT_"))}
    env.update(TMPDIR=scratch, LC_ALL="C")
    rows, pids, checks = [], set(), {}
    try:
        with (ROOT / "r-hot-placement.partial.jsonl").open("w") as journal:
            for row, launch in schedule():
                label, block = row["comparison"], row["block"]
                placement = PLACEMENTS[label]
                group = f"{label}/{block}"
                if group not in checks:
                    replace(reference, placement)
                    checks[group] = {role: digest(ROOT / "bin" / role) for _, role in placement}
                arms = [sample(arm, role, measure["parse"], env) for arm, role in launch]
                if row["order"] == "RL":
                    arms.reverse()
                for (arm, role), result in zip(placement, arms):
                    assert (result["arm"], result["role"]) == (arm, role)
                    assert result["pid"] not in pids
                    pids.add(result["pid"])
                measure["ensure_equivalence"](*arms)
                rows.append({**row, "left": arms[0], "right": arms[1]})
                journal.write(json.dumps(rows[-1], separators=(",", ":")) + "\n")
                journal.flush()
                if row["pair"] == 10:
                    assert checks[group] == {role: digest(ROOT / "bin" / role) for _, role in placement}
                    print(label, block, checks[group], flush=True)
    finally:
        replace(reference, tuple(STOCK.items()))

    counts = Counter((r["comparison"], r["block"], r["order"]) for r in rows)
    assert len(rows) == 80 and len(pids) == 160 and len(counts) == 16 and set(counts.values()) == {5}
    return {"samples": rows, "placements": PLACEMENTS, "placedImages": checks,
            "metricsPerOperation": measure["summary"](rows, ("cpu_us", "wall_ns"))}


def main():
    measure = runpy.run_path(str(ROOT / "measure.py"))
    bindings = measure["verify_bindings"]()
    before = runtime()
    image = ROOT / "r-hot-images"
    image.mkdir()
    (image / "runtime-before.json").write_text(json.dumps(before, indent=2) + "\n")
    for role in STOCK.values():
        record_image(role, bindings[f"bin/{role}"], image)
    with TemporaryDirectory(prefix="r-hot-placements.", dir=ROOT) as temporary:
        result = timings(measure, bindings, Path(temporary))
    after = runtime()
    (image / "runtime-after.json").write_text(json.dumps(after, indent=2) + "\n")
    assert before == after and measure["verify_bindings"]() == bindings
    result.update(bindings=bindings, runtime=before, toolSHA256=digest(Path(__file__)))
    (ROOT / "r-hot-placement.json").write_text(json.dumps(result, separators=(",", ":")) + "\n")


if __name__ == "__main__":
    main()
