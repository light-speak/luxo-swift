#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")/.."
baseline="${1:?Pass an unmodified WebSocketTransport.swift snapshot}"
case "${2:-payload}" in
  payload)
    expected=fa82cf493294e4b319f202ca0fa069ef84faac9c71ca71fd49efbf5e79954bdd
    baseline_class=PrePayloadWebSocketTransport
    baseline_protocol=BenchmarkTransport
    define=LUXO_PAYLOAD_BENCHMARK
    mode=--payload-mode
    ;;
  decode)
    expected=bf3c23c2e38b5ccd8da325577b00bc6334361f605566f10ff124472a8bbcf324
    baseline_class=PreDecodeWebSocketTransport
    baseline_protocol=Transport
    define=LUXO_DECODING_BENCHMARK
    mode=--decoding
    ;;
  *) echo 'Expected payload or decode benchmark' >&2; exit 1 ;;
esac
actual="$(shasum -a 256 "$baseline" | awk '{print $1}')"
[[ "$actual" == "$expected" ]] || { echo 'Unexpected baseline snapshot' >&2; exit 1; }
mkdir -p .tmp
scratch="$(mktemp -d "$(pwd)/.tmp/swift-payload.XXXXXX")"
cleanup() {
  case "$scratch" in
    "$(pwd)/.tmp/swift-payload."*) rm -rf -- "$scratch" ;;
    *) echo 'Refusing cleanup outside the benchmark scratch directory' >&2; exit 1 ;;
  esac
}
trap cleanup EXIT
ruby - "$baseline" "$scratch/Baseline.swift" "$baseline_class" "$baseline_protocol" <<'RUBY'
source, destination, class_name, protocol_name = ARGV
body = File.read(source)[/public final class WebSocketTransport:.*\z/m]
abort 'Missing baseline transport' unless body
body = body.gsub(/\bWebSocketTransport\b/, class_name)
body = body.sub(': Transport,', ": #{protocol_name},")
File.write(destination, "import Foundation\n\n" + body)
RUBY
swiftc -swift-version 6 -O -whole-module-optimization -warnings-as-errors \
  -parse-as-library -D "$define" \
  Sources/LuxoClient/*.swift Benchmarks/*.swift "$scratch/Baseline.swift" -o "$scratch/benchmark"
for run in 1 2 3; do
  printf 'Run %s; snapshot SHA-256 %s\n' "$run" "$expected"
  "$scratch/benchmark" "$mode"
done
