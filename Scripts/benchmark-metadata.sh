#!/usr/bin/env bash
set -euo pipefail

cd "$(dirname "$0")/.."
baseline=7f2f89eac4b231c70b8b848b54f1cbbb267b9d17
git cat-file -e "${baseline}:Sources/LuxoClient/Codec.swift"
mkdir -p .tmp
scratch="$(mktemp -d "$(pwd)/.tmp/codec-metadata.XXXXXX")"
cleanup() {
  case "$scratch" in
    "$(pwd)/.tmp/codec-metadata."*) rm -rf -- "$scratch" ;;
    *) echo 'Refusing cleanup outside the benchmark scratch directory' >&2; exit 1 ;;
  esac
}
trap cleanup EXIT

# Extract an immutable decoder baseline without changing the worktree or production code.
ruby - "$baseline" "$scratch/LegacyCodec.swift" <<'RUBY'
revision, destination = ARGV
source = IO.popen(['git', 'show', "#{revision}:Sources/LuxoClient/Codec.swift"], &:read)
abort 'Unable to read the frozen decoder' unless $?.success?
limits = source[/private enum CodecLimits \{.*?^\}/m]
decoders = source[/public struct Decoder \{.*?(?=\/\/ MARK: - FieldMask)/m]
abort 'Frozen decoder boundaries changed' unless limits && decoders
baseline = "import Foundation\n\n#{limits}\n\n#{decoders}"
%w[Decoder ColumnarDecoder CodecLimits].each do |name|
  baseline.gsub!(/\b#{name}\b/, "Legacy#{name}")
end
File.write(destination, baseline)
RUBY

swiftc -swift-version 6 -O -whole-module-optimization -warnings-as-errors \
  -parse-as-library -D LUXO_METADATA_BENCHMARK \
  Sources/LuxoClient/*.swift Benchmarks/*.swift "$scratch/LegacyCodec.swift" \
  -o "$scratch/benchmark"
for run in 1 2 3; do
  printf 'Run %s; frozen baseline %s\n' "$run" "$baseline"
  "$scratch/benchmark" --codec-metadata
done
