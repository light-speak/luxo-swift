#!/bin/bash
set -euo pipefail
umask 077
input=$(cd "$(dirname "$0")" && pwd -P)
repo=$(cd "$input/../../.." && pwd -P)
parent=eb87139514e817df579c9b34dcd75422e09f0412
s=2a8108bbe2692c349069d71b2f5eb2f9a501c171
s_tree=e86fd9264f0d875ca10967a4b56124c8dbc18e79
s_client=a76077acde23e0da5936e20c3b20acbd6024ae50
minus_tree=e457fb715025330006e7f4194c92a7e6f457f6e0
minus_client=214d2e0aac9d6bdcbc347b71657d153da66f4dd0
transport=Sources/LuxoClient/HTTPTransport.swift
s_blob=1890315dd1d99e8626b5a12424760287cd661cfb
minus_blob=505918acc33f6d19e8540c1720dafb8a4728e153
patch_sha=38b62c60a17e2ee32948199b9bbcd6e61becb746a2e7877b18a1fb51e11d63f0
s_manifest=d7d481636279149af83d6c04e7450e0d2297f53fdc5e333e273fd14d722bb311
minus_manifest=5239e6b2f2a32a672a43e790bfad63b8b3a1a7a9711e28aff0d6a1b56d47b8e1
sha256() { shasum -a 256 "$1" | awk '{print $1}'; }

if [[ "${1:-}" == --verify ]]; then
    test "$#" = 2
    verify_only=true
    product=$(cd "$2" && pwd -P)
    cd "$repo"
    test "$(git rev-parse HEAD)" = "$parent"
else
    test "$#" = 0
    verify_only=false
    cd "$repo"
    product="$repo/.tmp/s-product"
    out="$repo/.tmp/refresh-reentry-evidence"
    mkdir "$out"
    test "${GITHUB_EVENT_NAME:?}/${GITHUB_REPOSITORY:?}/${GITHUB_REF:?}" = \
        'push/light-speak/luxo-swift/refs/heads/diagnostics/http-refresh-reentry-scope'
    test "${RUNNER_KIND:?}/${RUNNER_OS:?}/${RUNNER_ARCH:?}" = 'github-hosted/macOS/ARM64'
    test "$(git --no-replace-objects rev-parse HEAD)" = "${GITHUB_SHA:?}"
    test "$(git --no-replace-objects show -s --format=%P HEAD)" = "$parent"
    git --no-replace-objects diff --name-status "$parent" HEAD > "$out/diagnostic-paths.txt"
    diff -u "$out/diagnostic-paths.txt" - <<'PATHS'
A	.github/diagnostics/http-refresh-reentry/hosted-s-sources.sha256
A	.github/diagnostics/http-refresh-reentry/minus-scope.patch.base64
A	.github/diagnostics/http-refresh-reentry/qualify-scope.py
A	.github/diagnostics/http-refresh-reentry/run-scope-attribution.sh
M	.github/workflows/diagnose-http-refresh-reentry.yml
PATHS
    test "${DEVELOPER_DIR:?}" = '/Applications/Xcode_26.6.app/Contents/Developer'
    {
        uname -a
        sw_vers
        sysctl -n machdep.cpu.brand_string
        xcodebuild -version
        swift --version
        xcrun --sdk macosx --show-sdk-version
    } > "$out/toolchain.txt"
    if [[ "$(uname -s)/$(uname -m)" != Darwin/arm64 ||
        "$(sw_vers -productVersion)/$(sw_vers -buildVersion)" != 26.7.2/25G332 ]] ||
        ! grep -Fxq 'Apple M1 (Virtual)' "$out/toolchain.txt" ||
        ! grep -Fxq 'Xcode 26.6' "$out/toolchain.txt" ||
        ! grep -Fxq 'Build version 17F113' "$out/toolchain.txt" ||
        ! grep -Fxq 'Apple Swift version 6.3.3 (swiftlang-6.3.3.1.3 clang-2100.1.1.101)' "$out/toolchain.txt" ||
        ! grep -Fxq '26.5' "$out/toolchain.txt"; then
        printf 'matched=false\nallocation_pairs=0\n' > "$out/status.txt"
        exit 3
    fi
fi

mkdir -p "$repo/.tmp"
work=$(mktemp -d "$repo/.tmp/scope-attribution.XXXXXXXX")
trap 'rm -rf -- "$work"' EXIT
trap 'exit 130' INT
trap 'exit 143' TERM
if [[ "$verify_only" == true ]]; then
    out="$work/verification"
    mkdir "$out"
fi
test "$(git --no-replace-objects -C "$product" rev-parse --show-toplevel)" = "$product"
test "$(git --no-replace-objects -C "$product" rev-parse HEAD 'HEAD^{tree}')" = "$s"$'\n'"$s_tree"
test "$(git --no-replace-objects -C "$product" rev-parse "$s:Sources/LuxoClient" "$s:$transport")" = "$s_client"$'\n'"$s_blob"
test -z "$(git --no-replace-objects -C "$product" status --porcelain)"
(cd "$input" && shasum -a 256 -c inputs.sha256)
test "$(sha256 "$input/hosted-s-sources.sha256")" = "$s_manifest"
python3 -I -B - "$input/minus-scope.patch.base64" "$work/ablation.patch" <<'PY'
from base64 import b64decode
from pathlib import Path
import sys
source, target = map(Path, sys.argv[1:])
target.write_bytes(b64decode(b"".join(source.read_bytes().split()), validate=True))
PY
test "$(sha256 "$work/ablation.patch")" = "$patch_sha"

sdk="$work/product"
git -c advice.detachedHead=false clone -q --shared --no-checkout "$product" "$sdk"
git -C "$sdk" switch -q --detach "$s"
git -C "$sdk" apply --index --check --whitespace=error-all "$work/ablation.patch"
git -C "$sdk" apply --index --whitespace=error-all "$work/ablation.patch"
test "$(git -C "$sdk" diff --cached --numstat)" = $'1\t1\t'"$transport"
test "$(git -C "$sdk" write-tree)" = "$minus_tree"
test "$(git -C "$sdk" rev-parse "$minus_tree:Sources/LuxoClient" ":$transport")" = "$minus_client"$'\n'"$minus_blob"
git -C "$sdk" diff --quiet
git -C "$sdk" apply --index --reverse --check "$work/ablation.patch"

mkdir "$work/source-s" "$work/source-minus"
git -C "$sdk" archive "$s" Sources/LuxoClient | tar -xf - -C "$work/source-s"
git -C "$sdk" archive "$minus_tree" Sources/LuxoClient | tar -xf - -C "$work/source-minus"
ordered=()
while read -r hash name; do ordered+=("$name"); done < "$input/hosted-s-sources.sha256"
test "${#ordered[@]}" = 29
for arm in source-s source-minus; do
    (cd "$work/$arm" && shasum -a 256 "${ordered[@]}") > "$out/$arm.sha256"
done
test "$(sha256 "$out/source-s.sha256")" = "$s_manifest"
test "$(sha256 "$out/source-minus.sha256")" = "$minus_manifest"
printf 'productCommit=%s\nA_intactTree=%s\nS_ablatedTree=%s\npatchSHA256=%s\n' \
    "$s" "$s_tree" "$minus_tree" "$patch_sha" > "$out/source.txt"
if [[ "$verify_only" == true ]]; then
    cat "$out/source.txt"
    exit 0
fi

perf="$work/performance"
mkdir -p "$perf/bin" "$perf/split/bin" "$perf/split/base" "$perf/split/next" "$work/module-cache" "$work/tmp"
export TMPDIR="$work/tmp"
cp "$input/"{Probe.swift,measure.py,verify-timing.py,allocation-helper.py,allocation-attribution.py,qualify-r-hot-placement.py,qualify-s-parallel-followup.py,qualify-scope.py} "$perf/"
cp "$out/toolchain.txt" "$perf/"
cp "$out/source-s.sha256" "$perf/base-sources.sha256"
cp "$out/source-minus.sha256" "$perf/next-sources.sha256"
swift=$(xcrun --find swiftc)
sdk_path=$(xcrun --sdk macosx --show-sdk-path)
flags=(-sdk "$sdk_path" -swift-version 6 -j 2 -module-cache-path "$work/module-cache" -target arm64-apple-macosx13.0
       -parse-as-library -O -whole-module-optimization -g -module-name LuxoClient)
app_flags=("${flags[@]}")
app_flags[${#app_flags[@]}-1]=LuxoRefreshProbe
cd "$perf"
{ printf '%s\n' 'import LuxoClient'; cat Probe.swift; } > split/Probe.swift
for arm in base next; do
    source="$work/source-s"
    if [[ "$arm" == next ]]; then source="$work/source-minus"; fi
    files=()
    for name in "${ordered[@]}"; do files+=("$source/$name"); done
    "$swift" "${flags[@]}" "${files[@]}" "$perf/Probe.swift" -o "$perf/bin/$arm" > "$out/build-joint-$arm.log" 2>&1
    library="$perf/split/$arm"
    "$swift" "${flags[@]}" -disable-cmo -emit-library -static -emit-module \
        -emit-module-path "$library/LuxoClient.swiftmodule" "${files[@]}" -o "$library/libLuxoClient.a" \
        > "$out/build-split-library-$arm.log" 2>&1
    "$swift" "${app_flags[@]}" -disable-cmo -I "$library" split/Probe.swift "$library/libLuxoClient.a" \
        -o "split/bin/$arm" > "$out/build-split-probe-$arm.log" 2>&1
done
shasum -a 256 Probe.swift measure.py verify-timing.py allocation-helper.py base-sources.sha256 \
    next-sources.sha256 toolchain.txt bin/base bin/next > binding.sha256
cp binding.sha256 "$out/"
python3 -I -B qualify-scope.py "$out" 2>&1 | tee "$out/allocations.log"
printf 'matched=true\nallocation_pairs=36\n' > "$out/status.txt"
