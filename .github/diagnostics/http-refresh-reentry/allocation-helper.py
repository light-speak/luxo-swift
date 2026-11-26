import json
import os
from pathlib import Path
import re
import select
import statistics as stats
import subprocess
import sys
import tempfile

ROOT = Path(__file__).resolve().parent
CASES = [(scenario, codec) for scenario in ('normal-off', 'normal', 'single', 'expiry') for codec in ('json', 'binary')]
FIELDS = ('iterations', 'successes', 'sends', 'refreshes', 'cpu_us', 'wall_ns')
BLOCK = re.compile(r'\n(?=(?:ALLOC|FREE|VM_ALLOC|VM_DEALLOC) )')


def command(role, scenario, codec, count, mode):
    return [str(ROOT / 'bin' / role), scenario, codec, role, str(count), mode]


def parse(line, role, scenario, codec, count):
    actual_scenario, actual_codec, actual_role, *values = line.strip().split(',')
    assert (actual_scenario, actual_codec, actual_role) == (scenario, codec, role), line
    assert len(values) == len(FIELDS), line
    row = dict(zip(FIELDS, map(int, values)))
    assert row['iterations'] == count and row['cpu_us'] > 0 and row['wall_ns'] > 0, row
    expired_peers = {'single': 1, 'expiry': 3}.get(scenario, 0)
    assert row['successes'] == (count * 3 if expired_peers == 3 and role == 'next' else count), row
    assert row['sends'] == (count * expired_peers + row['successes'] if expired_peers else count), row
    bounds = (count, count * (expired_peers if role == 'base' else 1)) if expired_peers else (0, 0)
    assert bounds[0] <= row['refreshes'] <= bounds[1], row
    return {'scenario': scenario, 'codec': codec, 'role': role, **row}


def stats_by_pair(pairs, key):
    values = [(right[key] - left[key]) / left[key] * 100 for left, right in pairs]
    return dict(base=stats.median(left[key] / left['iterations'] for left, _ in pairs),
                next=stats.median(right[key] / right['iterations'] for _, right in pairs),
                median_pct=stats.median(values), min_pct=min(values), max_pct=max(values))


def timings():
    rows = []
    for scenario, codec in CASES:
        count = {'normal-off': 30000, 'normal': 30000, 'single': 8000, 'expiry': 2000}[scenario]
        for comparison in ('AA', 'AB'):
            for block in range(2):
                pairs = []
                for pair in range(10):
                    flipped = (block + pair) % 2 == 1
                    right = 'base' if comparison == 'AA' else 'next'
                    roles = ('base', right)
                    records = []
                    for index in (1, 0) if flipped else (0, 1):
                        role = roles[index]
                        result = subprocess.check_output(command(role, scenario, codec, count, 'timing'),
                                                         text=True, timeout=35)
                        records.append(parse(result, role, scenario, codec, count))
                    if flipped:
                        records.reverse()
                    pairs.append(records)
                metrics = {key: stats_by_pair(pairs, key) for key in ('cpu_us', 'wall_ns')}
                rows.append(dict(scenario=scenario, codec=codec, comparison=comparison, block=block + 1,
                                 order=[('BA' if (block + pair) % 2 else 'AB') for pair in range(10)],
                                 pairs=pairs, metrics=metrics))
                print(scenario, codec, comparison, block + 1, metrics, flush=True)
    (ROOT / 'timing.json').write_text(json.dumps(rows, indent=2) + '\n')


def traced_allocations(history):
    active = False
    ended = False
    events = count = total = 0
    for block in BLOCK.split(history):
        first = block.split('\n', 1)[0]
        if not first.startswith('ALLOC '):
            continue
        size = int(re.search(r'\[size=(\d+)\]', first)[1])
        events += 1
        if 'phaseStart()' in block:
            assert not active and not ended and size == 23457
            active = True
        elif 'phaseEnd()' in block:
            assert active and not ended and size == 34569
            active = False
            ended = True
        elif active:
            count += 1
            total += size
    assert ended and count and total and events > count
    return dict(allocations=count, requested_bytes=total, process_allocations=events)


def allocation_sample(role, scenario, codec, count, env):
    with subprocess.Popen(command(role, scenario, codec, count, 'allocation'), env=env,
                          stdin=subprocess.PIPE, stdout=subprocess.PIPE, text=True) as target:
        try:
            if not select.select([target.stdout], [], [], 15)[0]:
                raise RuntimeError('probe did not print its result')
            row = parse(target.stdout.readline(), role, scenario, codec, count)
            traced = subprocess.run(['/usr/bin/malloc_history', str(target.pid), '-allEvents',
                                     '-noContent', '-fullStacks'], capture_output=True, text=True, timeout=25)
            assert traced.returncode == 0, (traced.stderr, traced.stdout[:800])
            title = next(line for line in traced.stdout.splitlines() if line.startswith('Process:'))
            assert re.fullmatch(r'Process:\s+' + role + rf' \[{target.pid}\]', title), title
            row.update(traced_allocations(traced.stdout), pid=target.pid, history_header=title)
            target.communicate('\n', timeout=10)
            assert target.returncode == 0, target.returncode
            return row
        finally:
            if target.poll() is None:
                target.kill()
                target.wait()


def allocations():
    rows = []
    with tempfile.TemporaryDirectory(prefix='malloc-events-', dir=ROOT) as temporary:
        env = dict(os.environ, MallocStackLoggingNoCompact='1', MallocStackLoggingDirectory=temporary,
                   TMPDIR=str(ROOT.parent / 'temporary'))
        env.pop('MallocStackLogging', None)
        for scenario, codec in CASES:
            count = 160 if scenario.startswith('normal') else 24
            for comparison in ('AA', 'AB'):
                for pair in range(5):
                    roles = ('base', 'base' if comparison == 'AA' else 'next')
                    flipped = pair % 2 == 1
                    records = [allocation_sample(roles[index], scenario, codec, count, env)
                               for index in ((1, 0) if flipped else (0, 1))]
                    if flipped:
                        records.reverse()
                    rows.append(dict(scenario=scenario, codec=codec, comparison=comparison, pair=pair + 1,
                                     order=('BA' if flipped else 'AB'), base=records[0], next=records[1]))
                    print(scenario, codec, comparison, pair + 1,
                          {key: (records[0][key], records[1][key])
                           for key in ('allocations', 'requested_bytes')}, flush=True)
    (ROOT / 'allocation-pairs.json').write_text(json.dumps(rows, indent=2) + '\n')


if __name__ == '__main__':
    {'timing': timings, 'allocation': allocations}[sys.argv[1]]()
