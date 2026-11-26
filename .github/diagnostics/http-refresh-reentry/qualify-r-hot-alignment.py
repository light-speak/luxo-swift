"""Verify linked entry alignment before comparing it on one native worker."""

from collections import Counter
from hashlib import sha256
import json
import os
from pathlib import Path
import re
import runpy
from tempfile import TemporaryDirectory

ROOT = Path(__file__).resolve().parent
ARMS = ("base", "next", "base-aligned", "next-aligned")
HOT = ("callRequest", "performRequest", "doCall", "decodeJSONResponse")
EXPECTED_SYMBOL_COUNT = 26
WORKLOAD = ("normal-off", "json", 30_000)
COMPARISONS = {
    "AR-stock": ("base", "next"),
    "AR-aligned": ("base-aligned", "next-aligned"),
    "A-stock-aligned": ("base", "base-aligned"),
    "R-stock-aligned": ("next", "next-aligned"),
}
INSTRUCTION = re.compile(r"^([0-9a-fA-F]+):\s+(?:[0-9a-fA-F]{2}\s+){4}(.+)$", re.M)
ADDRESS = re.compile(r"(?<![#\w])-?0x[0-9a-fA-F]+")
VALUE = r"#?-?(?:0x[0-9a-fA-F]+|[0-9]+)"
PAGE = re.compile(rf"^(adrp?) (x[0-9]+), {VALUE}$")
PAGE_ADD = re.compile(rf"^add (x[0-9]+), (x[0-9]+), {VALUE}$")
ADDRESS_REGISTER = re.compile(rf"\[(x[0-9]+)(?:, {VALUE})?\](?![!,])")
LITERAL = re.compile(rf"^((?:ldr|ldrsw|prfm) [a-zA-Z0-9]+), {VALUE}$")
FIRST_DESTINATION = re.compile(r"^[^ ]+ [xw]([0-9]+)[, ]")
DIRECT_BRANCH = re.compile(r"^(?:b(?:\.[a-z]+)?|bl|cbn?z|tbn?z)\b")



def verify_alignment(images):
    slots = {}
    for arm in ARMS:
        offsets = images[arm]["offsetsFromTextVMAddr"]
        selected = [(offset, symbol) for offset, symbol in offsets
                    if "ProbeBackend" in symbol and any(name in symbol for name in HOT)]
        slots[arm] = {symbol: offset for offset, symbol in selected}
        assert len(slots[arm]) == len(selected) == EXPECTED_SYMBOL_COUNT, arm
    keys = slots["base"].keys()
    assert all(slots[arm].keys() == keys for arm in ARMS)
    rows = [{"symbol": name, "offsets": {arm: slots[arm][name] for arm in ARMS},
             "mod64": {arm: slots[arm][name] % 64 for arm in ARMS}}
            for name in sorted(keys)]
    assert any(row["mod64"]["base"] != row["mod64"]["next"] for row in rows)
    violations = {f"{row['symbol']}/{arm}": row["mod64"][arm]
                  for row in rows for arm in ("base-aligned", "next-aligned") if row["mod64"][arm]}
    return rows, violations


def instruction_stream(output, symbol, start):
    assert f"{symbol}:" in output.splitlines(), symbol
    rows = [(int(addr, 16), operation.strip()) for addr, operation in INSTRUCTION.findall(output)]
    assert rows and [address for address, _ in rows] == list(range(start, start + 4 * len(rows), 4)), symbol
    while rows and rows[-1][1] == "nop":
        rows.pop()
    assert rows and not any("<unknown>" in operation for _, operation in rows), symbol
    end = start + 4 * len(rows)
    result = []
    for _, operation in rows:
        code, _, comment = operation.partition(";")
        if DIRECT_BRANCH.match(code):
            def target(match):
                destination = int(match[0], 16)
                return f"local+{destination-start}" if start <= destination < end else "<image>"
            code = ADDRESS.sub(target, code)
            if "symbol stub for:" in comment:
                code += " " + comment.strip()
        result.append(" ".join(code.split()))
    return result


def normalize(operations):
    pages = set()
    normalized = []
    for operation in operations:
        if page := PAGE.fullmatch(operation):
            opcode, register = page.groups()
            pages.discard(register)
            if opcode == "adrp":
                pages.add(register)
            normalized.append(f"{opcode} {register}, <pc-relative>")
            continue
        if addition := PAGE_ADD.fullmatch(operation):
            destination, base = addition.groups()
            if base in pages:
                operation = f"add {destination}, {base}, <page-offset>"
        if operation.startswith(("ld", "st")):
            def replace_address(match):
                base = match[1]
                return f"[{base}, <page-offset>]" if base in pages else match[0]
            operation = ADDRESS_REGISTER.sub(replace_address, operation)
            operation = LITERAL.sub(r"\1, <pc-relative>", operation)
        if DIRECT_BRANCH.match(operation) or operation.startswith(("blr ", "br ", "ret")):
            pages.clear()
        elif not operation.startswith(("st", "cmp ", "cmn ", "tst ", "prfm ")):
            if destination := FIRST_DESTINATION.match(operation):
                pages.discard("x" + destination[1])
        normalized.append(operation)
    return normalized


def identify_code(helpers, images, rows, out):
    states = {arm: {} for arm in ARMS}
    for arm in ARMS:
        binary = ROOT / "bin" / arm
        for row in rows:
            symbol = row["symbol"]
            discovered = images[arm]["textVMAddr"] + row["offsets"][arm]
            output = helpers["command"](
                "xcrun", "llvm-objdump", "--macho", "--disassemble", "--dis-symname", symbol, str(binary)
            )
            states[arm][symbol] = instruction_stream(output, symbol, discovered)
    summary = {}
    for name, (left, right) in COMPARISONS.items():
        sig = {}
        for symbol in states[left]:
            lops, rops = states[left][symbol], states[right][symbol]
            normalized_a, normalized_b = map(normalize, (lops, rops))
            sig[symbol] = {
                "instructions": [len(lops), len(rops)],
                "instructionSHA256": [sha256("\n".join(ops).encode()).hexdigest() for ops in (lops, rops)],
                "shapeSHA256": [sha256("\n".join(ops).encode()).hexdigest() for ops in (normalized_a, normalized_b)],
                "sameNormalizedInstructions": normalized_a == normalized_b,
                "firstOperandDifference": next((
                    {"index": index, "left": a, "right": b}
                    for index, (a, b) in enumerate(zip(lops, rops)) if a != b
                ), None),
                "firstNormalizedDifference": next((
                    {"index": index, "left": a, "right": b}
                    for index, (a, b) in enumerate(zip(normalized_a, normalized_b)) if a != b
                ), None),
            }
        summary[name] = sig
    (out / "instructions.json").write_text(json.dumps(summary, indent=2) + "\n")
    return summary


def schedule():
    scenario, codec, _ = WORKLOAD
    comparisons = list(COMPARISONS)
    for block in (1, 2):
        for offset in range(10):
            pivot = (block + offset - 1) % len(comparisons)
            turn = comparisons[pivot:] + comparisons[:pivot]
            flip = (block + offset) % 2 == 0
            swapped = ((offset // 2 + offset % 2) % 2 == 1) != (block == 2)
            for comparison in turn:
                slots = ("next", "base") if swapped else ("base", "next")
                placement = tuple(zip(COMPARISONS[comparison], slots))
                meta = dict(block=block, pair=offset+1, comparison=comparison, order="RL" if flip else "LR",
                            scenario=scenario, codec=codec)
                yield meta, placement, placement[::-1] if flip else placement


def place(reference, placements):
    for arm, role in placements:
        slot = ROOT / "bin" / role
        image = reference / arm
        if slot.samefile(image):
            continue
        pending = slot.with_suffix(".new")
        os.link(image, pending)
        try:
            pending.replace(slot)
        finally:
            pending.unlink(missing_ok=True)
        assert slot.samefile(image)


def timings(measure, helpers, digests, out, scratch):
    reference = scratch / "reference"
    reference.mkdir()
    for arm in ARMS:
        os.link(ROOT / "bin" / arm, reference / arm)
        assert helpers["digest"](reference / arm) == digests[arm]
    env = {key: value for key, value in os.environ.items()
           if not key.startswith(("MallocStackLogging", "DYLD_PRINT_"))}
    env.update(TMPDIR=scratch, LC_ALL="C")
    rows, identities = [], set()
    try:
        with (out / "timing.partial.jsonl").open("w") as journal:
            for meta, placement, launch in schedule():
                place(reference, placement)
                samples = [helpers["sample"](arm, role, measure["parse"], env) for arm,role in launch]
                if meta["order"] == "RL":
                    samples.reverse()
                for (arm, role), observed in zip(placement, samples):
                    assert (observed["arm"], observed["role"]) == (arm, role)
                    assert observed["pid"] not in identities
                    assert (observed["scenario"], observed["codec"], observed["iterations"]) == WORKLOAD
                    identities.add(observed["pid"])
                    observed["imageSHA256"] = digests[arm]
                measure["ensure_equivalence"](*samples)
                rows.append({**meta, "left": samples[0], "right": samples[1]})
                journal.write(json.dumps(rows[-1], separators=(",", ":")) + "\n")
                journal.flush()
    finally:
        place(reference, (("base", "base"), ("next", "next")))
    assert all(helpers["digest"](ROOT / "bin" / arm) == digests[arm] for arm in ARMS)
    directions = Counter((v["comparison"], v["block"], v["order"]) for v in rows)
    slots = Counter((v["comparison"], v["block"], v["left"]["role"]) for v in rows)
    assert len(rows) == 80 and len(identities) == 160
    assert len(directions) == len(slots) == 16 and set(directions.values()) == set(slots.values()) == {5}
    return {"samples": rows, "metricsPerOperation": measure["summary"](rows, ("cpu_us", "wall_ns"))}


def main():
    measure = runpy.run_path(str(ROOT / "measure.py"))
    helpers = runpy.run_path(str(ROOT / "qualify-r-hot-placement.py"))
    binding = measure["verify_bindings"]()
    out = ROOT / "r-hot-alignment"
    out.mkdir()
    boot = helpers["runtime"]()
    recorded = {}
    linked = {}
    digests = {}
    for arm in ARMS:
        sha = helpers["digest"](ROOT / "bin" / arm)
        if arm in ("base", "next"):
            assert sha == binding[f"bin/{arm}"], arm
        digests[arm] = sha
        helpers["record_image"](arm, sha, out)
        recorded[arm] = json.loads((out / f"{arm}-hot-symbols.json").read_text())
        linked[arm] = (out / f"{arm}-linked-images.txt").read_text().splitlines()[1:]
    assert len(set(digests.values())) == 4
    assert all(linked[arm] == linked["base"] for arm in ARMS)
    rows, violations = verify_alignment(recorded)
    assert helpers["runtime"]() == boot and measure["verify_bindings"]() == binding
    report = {"binding": binding, "boot": boot, "binariesSHA256": digests, "alignmentRows": rows,
              "misalignedEntries": violations, "alignmentFlags": ["-Xllvm", "-align-all-functions=6"],
              "toolSHA256": helpers["digest"](Path(__file__)), "recordedBeforeTiming": True}
    (out / "alignment.json").write_text(json.dumps(report, indent=2) + "\n")
    assert not violations, violations
    print(f"Matched {len(rows)} hot symbols in four linked binaries. Both aligned entries have mod64 zero.")
    instructions = identify_code(helpers, recorded, rows, out)
    for comparison, symbols in instructions.items():
        changed = [name for name, state in symbols.items() if not state["sameNormalizedInstructions"]]
        assert not changed, (comparison, changed)
    assert helpers["runtime"]() == boot
    with TemporaryDirectory(prefix="r-hot-alignment.", dir=ROOT) as scratch:
        timed = timings(measure, helpers, digests, out, Path(scratch))
    terminal = helpers["runtime"]()
    (out / "runtime-after.json").write_text(json.dumps(terminal, indent=2) + "\n")
    assert terminal == boot and measure["verify_bindings"]() == binding
    timed.update(binding=binding, binariesSHA256=digests, boot=boot,
                 instructionsSHA256=helpers["digest"](out / "instructions.json"))
    (out / "timing.json").write_text(json.dumps(timed, separators=(",", ":")) + "\n")


if __name__ == "__main__":
    main()
