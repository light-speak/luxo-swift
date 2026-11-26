#!/usr/bin/env bash
set -euo pipefail
umask 077
phase=${1:?Expected test, performance or allocation-stacks}
case "$phase" in test|performance|allocation-stacks) ;; *) exit 2 ;; esac
cd "${GITHUB_WORKSPACE:?}"
repo=$(pwd -P)
base=d6578969bcef258141c7c99cb6cface30a22a0e2
diagnostic_parent=c42a1abda08d57ad58daaed502ec6ddaad3f36a1
direct_parent=611c80754edcdd5413fc7d1a67b4c9d7d6c1626d
pq_initial=1a1b3fc090e8dbe06ff309aab7d37d78cd452c22
initial_diagnostic=35e593a50854cc208ac52f8aad9e5be3f06b9138
prior=c106719f7f78608173fcbe522f90064552f32b4a
candidate=8dd7fd238fbbb4bd195f2083650174339946d50a
optimization_patch_digest=ba9e4d01f2d6b665d77e19cd973fdfd9e7f5c84f8ebec9de4f7ffedf99e207fd
base_sources=dbdaed8acd534ea691215f839b6e57a4504c333a
prior_sources=e89a325d40b0e0cd334cb0ffbf9c428dc9b2e6e2
candidate_sources=e8bfbe73d97942739a3de11033202fcb5f5b437a
patch_digest=5c26ee2f33344a2554faa9f905df4c9eed999d142b2fe5d3ae4745e9a9096024
lock_digest=b591abc67a0576311e15869bc841db99743f9f0398b6a8828e78984a86079fd2
core_revision=a2c411b7b83ca233881ace0c5bf3bec0b9646e1d
input="$repo/.github/diagnostics/http-refresh-reentry"
out="$repo/.tmp/refresh-reentry-evidence"
mkdir -p "$repo/.tmp"
mkdir "$out"
work=$(mktemp -d "$repo/.tmp/refresh-reentry-native.XXXXXXXX")
trap 'rm -rf -- "$work"' EXIT
trap 'exit 130' INT
trap 'exit 143' TERM
test "$(git rev-parse HEAD)" = "${GITHUB_SHA:?}"
test "$(git show -s --format=%P HEAD)" = "$diagnostic_parent"
test "$(git show -s --format=%P "$diagnostic_parent")" = "$direct_parent"
test "$(git show -s --format=%P "$direct_parent")" = "$pq_initial"
test "$(git show -s --format=%P "$pq_initial")" = "$initial_diagnostic"
test "$(git show -s --format=%P "$initial_diagnostic")" = "$base"
test "$(uname -s)/$(uname -m)" = 'Darwin/arm64'
test "${RUNNER_OS:?}/${RUNNER_ARCH:?}" = 'macOS/ARM64'
test "${DEVELOPER_DIR:?}" = '/Applications/Xcode_26.6.app/Contents/Developer'
test "$(sw_vers -productVersion | cut -d. -f1)" = 26
{
    uname -a
    sw_vers
    sysctl -n machdep.cpu.brand_string || printf 'CPU brand not exposed\n'
    xcodebuild -version
    swift --version
    xcrun --sdk macosx --show-sdk-version
    printf 'Runner ImageOS=%s ImageVersion=%s\n' "${ImageOS:-not-reported}" "${ImageVersion:-not-reported}"
} > "$out/toolchain.txt"
grep -Eq '^Apple Swift version 6\.3\.3 ' "$out/toolchain.txt"
grep -Fx 'Xcode 26.6' "$out/toolchain.txt"
(
    cd "$input"
    shasum -a 256 -c inputs.sha256
)
sha256() { shasum -a 256 "$1" | awk '{print $1}'; }
python3 - "$input" "$work" <<'PY'
import base64
from pathlib import Path
import sys
for patch in ("candidate.patch", "optimization.patch"):
    source = Path(sys.argv[1]) / (patch + ".base64")
    data = b"".join(source.read_bytes().splitlines())
    (Path(sys.argv[2]) / patch).write_bytes(base64.b64decode(data, validate=True))
PY
test "$(sha256 "$work/candidate.patch")" = "$patch_digest"
test "$(sha256 "$work/optimization.patch")" = "$optimization_patch_digest"
test "$(sha256 "$input/pins.json")" = "$lock_digest"
sdk="$work/sdk"
git clone -q --shared --no-checkout "$repo" "$sdk"
git -C "$sdk" switch -q --detach "$base"
git -C "$sdk" apply --index --whitespace=error-all "$work/candidate.patch"
test "$(git -C "$sdk" write-tree)" = "$prior"
test "$(git -C "$sdk" rev-parse "$prior:Sources/LuxoClient")" = "$prior_sources"
git -C "$sdk" apply --index --whitespace=error-all "$work/optimization.patch"
check_tree() {
    test "$(git -C "$sdk" rev-parse HEAD)" = "$base"
    test "$(git -C "$sdk" write-tree)" = "$candidate"
    git -C "$sdk" diff --exit-code
    git -C "$sdk" diff --cached --check
}
check_tree
test "$(git -C "$sdk" rev-parse "$base:Sources/LuxoClient")" = "$base_sources"
test "$(git -C "$sdk" rev-parse "$candidate:Sources/LuxoClient")" = "$candidate_sources"
printf 'diagnosticHead=%s\nbase=%s\ncandidateTree=%s\nbaseSourceTree=%s\ncandidateSourceTree=%s\npatchSHA256=%s\nlockSHA256=%s\n' \
    "$GITHUB_SHA" "$base" "$candidate" "$base_sources" "$candidate_sources" "$patch_digest" "$lock_digest" > "$out/source.txt"
git -C "$sdk" diff --cached --name-status > "$out/changed-paths.txt"
git -C "$sdk" diff --name-status "$prior" "$candidate" > "$out/changed-paths-from-p.txt"
printf 'diagnosticParent=%s\npriorCandidateTree=%s\npriorCandidateSourceTree=%s\ncomparisonBaseTree=%s\ncomparisonBaseSourceTree=%s\noptimizationPatchSHA256=%s\n' \
    "$diagnostic_parent" "$prior" "$prior_sources" "$base" "$base_sources" "$optimization_patch_digest" >> "$out/source.txt"
cp "$input/inputs.sha256" "$input/pins.json" "$out/"
mkdir "$work/tmp"
export TMPDIR="$work/tmp"
if [ "$phase" = test ]; then
    test "${LUXO_CORE_FIXTURE_REVISION:?}" = "$core_revision"
    core="$repo/.tmp/luxo-core"
    test "$(git -C "$core" rev-parse HEAD)" = "$core_revision"
    test "$(go version)" = 'go version go1.27.1 darwin/arm64'
    cp "$input/pins.json" "$sdk/Package.resolved"
    cd "$sdk"
    swift package --disable-automatic-resolution -j 2 resolve 2>&1 | tee "$out/resolve.log"
    test "$(sha256 "$sdk/Package.resolved")" = "$lock_digest"
    swift format lint --recursive --strict Sources Tests Benchmarks Package.swift 2>&1 | tee "$out/format.log"
    swift build --disable-automatic-resolution -j 2 -c release -Xswiftc -warnings-as-errors \
        -Xswiftc -strict-concurrency=complete 2>&1 | tee "$out/release-build.log"
    ios_sdk=$(xcrun --sdk iphoneos --show-sdk-path)
    minimum_mac_sdk=$(xcrun --sdk macosx --show-sdk-path)
    swiftc -typecheck -module-name LuxoClient -swift-version 6 -warnings-as-errors -strict-concurrency=complete \
            -target arm64-apple-ios15.0 -sdk "$ios_sdk" Sources/LuxoClient/*.swift 2>&1 | tee "$out/ios15-typecheck.log"
    swiftc -typecheck -module-name LuxoClient -swift-version 6 -warnings-as-errors -strict-concurrency=complete \
            -target x86_64-apple-macos13.0 -sdk "$minimum_mac_sdk" Sources/LuxoClient/*.swift 2>&1 | tee "$out/macos13-typecheck.log"
    python3 -m unittest discover -s Scripts -p 'test_*_test.py' 2>&1 | tee "$out/python-tests.log"
    status=0
    python3 Scripts/test-nio.py --all --coverage --core "$core" --core-revision "$core_revision" 2>&1 |
        tee "$out/full-tests.log" || status=$?
    for dir in .tmp/swift-nio-integration-*; do
        if [ -d "$dir" ]; then
            test ! -d "$dir/credentials"
            for file in result.json test.log swift-build.log; do
                if [ -f "$dir/$file" ]; then cp "$dir/$file" "$out/"; fi
            done
        fi
    done
    test "$status" = 0
    python3 "$input/check-native.py" "$out" full
    bash Scripts/check-coverage-test.sh 2>&1 | tee "$out/coverage-tool-tests.log"
    bash Scripts/check-coverage.sh 90.0 coverage.lcov 2>&1 | tee "$out/coverage-threshold.log"
    cp coverage.lcov "$out/"
    swift test --disable-sandbox --disable-automatic-resolution -j 2 --sanitize=thread \
        -Xswiftc -warnings-as-errors --filter HTTPBackendTests 2>&1 | tee "$out/http-tsan.log"
    python3 "$input/check-native.py" "$out" tsan
    test "$(sha256 "$sdk/Package.resolved")" = "$lock_digest"
else
    perf="$work/performance"
    mkdir "$perf" "$perf/bin" "$work/module-cache"
    cp "$input"/{Probe.swift,measure.py,verify-timing.py,allocation-helper.py} "$perf/"
    cp "$out/toolchain.txt" "$perf/"
    swift=$(xcrun --find swiftc)
    sdk_path=$(xcrun --sdk macosx --show-sdk-path)
    flags=(-sdk "$sdk_path" -swift-version 6 -j 2 -module-cache-path "$work/module-cache" -target arm64-apple-macosx13.0
           -parse-as-library -O -whole-module-optimization -g -module-name LuxoClient)
    for arm in base next; do
        tree=$base
        if [ "$arm" = next ]; then tree=$candidate; fi
        checkout="$work/$arm"
        mkdir "$checkout"
        git -C "$sdk" archive "$tree" Sources/LuxoClient | tar -xf - -C "$checkout"
        (cd "$checkout" && shasum -a 256 Sources/LuxoClient/*.swift) > "$perf/$arm-sources.sha256"
        "$swift" "${flags[@]}" "$checkout"/Sources/LuxoClient/*.swift "$perf/Probe.swift" \
            -o "$perf/bin/$arm" > "$out/build-$arm.log" 2>&1
    done
    cd "$perf"
    shasum -a 256 Probe.swift measure.py verify-timing.py allocation-helper.py base-sources.sha256 \
        next-sources.sha256 toolchain.txt bin/base bin/next > binding.sha256
    cp binding.sha256 base-sources.sha256 next-sources.sha256 "$out/"
    status=0
    python3 measure.py smoke 2>&1 | tee "$out/smoke.log" || status=$?
    if [ -f smoke.json ]; then cp smoke.json "$out/"; fi
    test "$status" = 0
    if [ "$phase" = allocation-stacks ]; then
        cp "$input/allocation-stacks.py" "$perf/"
        python3 allocation-stacks.py 2>&1 | tee "$out/allocation-stacks.log" || status=$?
        for file in allocation-stacks.json allocation-stacks.partial.jsonl; do
            if [ -f "$file" ]; then cp "$file" "$out/"; fi
        done
        test "$status" = 0
    else
        python3 measure.py timing 2>&1 | tee "$out/timing.log" || status=$?
        for file in timing.json timing.partial.jsonl; do
            if [ -f "$file" ]; then cp "$file" "$out/"; fi
        done
        test "$status" = 0
        python3 verify-timing.py 2>&1 | tee "$out/timing-verified.log"
        cp timing-verified.json "$out/"
        python3 measure.py allocations 2>&1 | tee "$out/allocations.log"
        cp allocations.json "$out/"
    fi
fi
check_tree
printf '%s\n' passed > "$out/status.txt"
