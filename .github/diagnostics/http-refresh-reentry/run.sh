#!/usr/bin/env bash
set -euo pipefail
umask 077
phase=${1:?Expected a native diagnostic phase}
case "$phase" in test|performance|allocation-stacks|allocation-attribution|r-residual|r-hot-placement|r-hot-alignment) ;; *) exit 2 ;; esac
cd "${GITHUB_WORKSPACE:?}"
repo=$(pwd -P)
base=d6578969bcef258141c7c99cb6cface30a22a0e2
diagnostic_parent=7ae6f660bc38efd47c89615602644418c64bedbe
placement_parent=f0e72b136f157e6b9d7ba9b92040b2dfa7c4537a
residual_parent=2745c87626cfb3f0d05060f5a2c278ad27f4c930
av_parent=3018b942b4c477b10c424072695d7278b739aafa
attribution_parent=6db74f84ef60aa2ea4046ef7a6e76f73097b4263
performance_parent=6f7f917eeae867a7e3ba54d514504e3e5d41f731
stacks_parent=d7869d4c2a4e6737d863322596b42589186bd118
allocation_parent=c42a1abda08d57ad58daaed502ec6ddaad3f36a1
direct_parent=611c80754edcdd5413fc7d1a67b4c9d7d6c1626d
pq_initial=1a1b3fc090e8dbe06ff309aab7d37d78cd452c22
initial_diagnostic=35e593a50854cc208ac52f8aad9e5be3f06b9138
prior=c106719f7f78608173fcbe522f90064552f32b4a
attributed_candidate=168f4f54dfeda7ae37d6a06c0754645ae98c792e
candidate=dac21227057bddb1d95bc872699515ab9301aaff
void_patch_digest=16c6e65fe799bc835ab6008a159bed132f91b32275c68f3a05ec2b84b42f4563
optimization_patch_digest=53549d30e67c3420c843fe045121b0524c27929314b1c1e76a4689c3a0673a86
base_sources=dbdaed8acd534ea691215f839b6e57a4504c333a
prior_sources=e89a325d40b0e0cd334cb0ffbf9c428dc9b2e6e2
attributed_sources=bc45cfd3ea3c107c494fb3a76a9274e1a8324318
candidate_sources=ea0383b2fc3dd454e54109ad6ba70a31f2639209
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
test "$(git show -s --format=%P "$diagnostic_parent")" = "$placement_parent"
test "$(git show -s --format=%P "$placement_parent")" = "$residual_parent"
test "$(git show -s --format=%P "$residual_parent")" = "$av_parent"
test "$(git show -s --format=%P "$av_parent")" = "$attribution_parent"
test "$(git show -s --format=%P "$attribution_parent")" = "$performance_parent"
test "$(git show -s --format=%P "$performance_parent")" = "$stacks_parent"
test "$(git show -s --format=%P "$stacks_parent")" = "$allocation_parent"
test "$(git show -s --format=%P "$allocation_parent")" = "$direct_parent"
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
if { [ "$phase" = r-hot-placement ] || [ "$phase" = r-hot-alignment ]; } && ! grep -Fxq 'Apple M1 (Virtual)' "$out/toolchain.txt"; then
    printf '%s\n' 'CPU did not match; no benchmark binaries or samples were produced.' > "$out/status.txt"
    exit 0
fi
(
    cd "$input"
    shasum -a 256 -c inputs.sha256
)
sha256() { shasum -a 256 "$1" | awk '{print $1}'; }
python3 - "$input" "$work" <<'PY'
import base64
from pathlib import Path
import sys
for patch in ("candidate.patch", "optimization.patch", "void-operation.patch"):
    source = Path(sys.argv[1]) / (patch + ".base64")
    data = b"".join(source.read_bytes().splitlines())
    (Path(sys.argv[2]) / patch).write_bytes(base64.b64decode(data, validate=True))
PY
test "$(sha256 "$work/candidate.patch")" = "$patch_digest"
test "$(sha256 "$work/optimization.patch")" = "$optimization_patch_digest"
test "$(sha256 "$work/void-operation.patch")" = "$void_patch_digest"
test "$(sha256 "$input/pins.json")" = "$lock_digest"
sdk="$work/sdk"
git clone -q --shared --no-checkout "$repo" "$sdk"
git -C "$sdk" switch -q --detach "$base"
git -C "$sdk" apply --index --whitespace=error-all "$work/candidate.patch"
test "$(git -C "$sdk" write-tree)" = "$prior"
test "$(git -C "$sdk" rev-parse "$prior:Sources/LuxoClient")" = "$prior_sources"
git -C "$sdk" apply --index --whitespace=error-all "$work/optimization.patch"
test "$(git -C "$sdk" write-tree)" = "$attributed_candidate"
test "$(git -C "$sdk" rev-parse "$attributed_candidate:Sources/LuxoClient")" = "$attributed_sources"
void_applied=false
if [ "$phase" = r-residual ] || [ "$phase" = r-hot-placement ] || [ "$phase" = r-hot-alignment ]; then
    candidate=$attributed_candidate
    candidate_sources=$attributed_sources
else
    git -C "$sdk" apply --index --whitespace=error-all "$work/void-operation.patch"
    void_applied=true
fi
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
git -C "$sdk" diff --name-status "$attributed_candidate" "$candidate" > "$out/changed-paths-from-r.txt"
printf 'attributedCandidateTree=%s\nattributedCandidateSourceTree=%s\nvoidOperationPatchSHA256=%s\nvoidOperationApplied=%s\n' \
    "$attributed_candidate" "$attributed_sources" "$void_patch_digest" "$void_applied" >> "$out/source.txt"
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
        if [ "$phase" = r-hot-alignment ]; then
            "$swift" "${flags[@]}" -Xllvm -align-all-functions=6 "$checkout"/Sources/LuxoClient/*.swift "$perf/Probe.swift" \
                -o "$perf/bin/$arm-aligned" > "$out/build-$arm-aligned.log" 2>&1
        fi
    done
    cd "$perf"
    shasum -a 256 Probe.swift measure.py verify-timing.py allocation-helper.py base-sources.sha256 \
        next-sources.sha256 toolchain.txt bin/base bin/next > binding.sha256
    cp binding.sha256 base-sources.sha256 next-sources.sha256 "$out/"
    status=0
    if [ "$phase" != r-hot-placement ] && [ "$phase" != r-hot-alignment ]; then
        python3 measure.py smoke 2>&1 | tee "$out/smoke.log" || status=$?
        if [ -f smoke.json ]; then cp smoke.json "$out/"; fi
        test "$status" = 0
    fi
    if [ "$phase" = r-hot-alignment ]; then
        cp "$input"/{qualify-r-hot-placement.py,qualify-r-hot-alignment.py} "$perf/"
        python3 qualify-r-hot-alignment.py 2>&1 | tee "$out/r-hot-alignment.log" || status=$?
        if [ -d r-hot-alignment ]; then mv r-hot-alignment "$out/"; fi
        test "$status" = 0
    elif [ "$phase" = r-hot-placement ]; then
        cp "$input/qualify-r-hot-placement.py" "$perf/"
        python3 qualify-r-hot-placement.py 2>&1 | tee "$out/r-hot-placement.log" || status=$?
        for file in r-hot-placement.json r-hot-placement.partial.jsonl r-hot-images; do
            if [ -e "$file" ]; then mv "$file" "$out/"; fi
        done
        test "$status" = 0
    elif [ "$phase" = r-residual ]; then
        cp "$input"/{allocation-attribution.py,qualify-r-residual.py} "$perf/"
        for residual_phase in timing allocation; do
            python3 qualify-r-residual.py "$residual_phase" 2>&1 |
                tee "$out/r-residual-$residual_phase.log" || status=$?
            for file in "r-residual-$residual_phase.json" "r-residual-$residual_phase.partial.jsonl" r-residual-raw; do
                if [ -e "$file" ]; then mv "$file" "$out/"; fi
            done
            test "$status" = 0
        done
    elif [ "$phase" = allocation-attribution ]; then
        cp "$input/allocation-attribution.py" "$perf/"
        python3 allocation-attribution.py 2>&1 | tee "$out/allocation-attribution.log" || status=$?
        for file in allocation-attribution.json allocation-attribution.partial.jsonl allocation-attribution-raw; do
            if [ -e "$file" ]; then mv "$file" "$out/"; fi
        done
        test "$status" = 0
    elif [ "$phase" = allocation-stacks ]; then
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
