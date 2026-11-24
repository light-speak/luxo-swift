#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")/.."
baseline="${1:?Pass the unmodified pre-disconnect WebSocketTransport.swift snapshot}"
expected=06029cf8c0dd0c18ec4e9822c10843320927fe4ec3670342e2f124b8207495a8
actual="$(shasum -a 256 "$baseline" | awk '{print $1}')"
[[ "$actual" == "$expected" ]] || { echo 'Unexpected baseline snapshot' >&2; exit 1; }
mkdir -p .tmp
scratch="$(mktemp -d "$(pwd)/.tmp/swift-disconnect.XXXXXX")"
cleanup() {
  case "$scratch" in
    "$(pwd)/.tmp/swift-disconnect."*) rm -rf -- "$scratch" ;;
    *) echo 'Refusing cleanup outside the benchmark scratch directory' >&2; exit 1 ;;
  esac
}
trap cleanup EXIT

# Only rename the captured transport; unchanged wire helpers are shared by both variants.
ruby - "$baseline" "$scratch/PreDisconnect.swift" <<'RUBY'
source, destination = ARGV
text = File.read(source)
body = text[/public final class WebSocketTransport:.*\z/m]
abort 'Missing baseline transport' unless body
body = body.gsub(/\bWebSocketTransport\b/, 'PreDisconnectWebSocketTransport')
body = body.sub(': Transport,', ': BenchmarkTransport,')
File.write(destination, "import Foundation\n\n" + body)
RUBY
swiftc -swift-version 6 -O -whole-module-optimization -warnings-as-errors \
  -parse-as-library -D LUXO_DISCONNECT_BENCHMARK \
  Sources/LuxoClient/*.swift Benchmarks/*.swift "$scratch/PreDisconnect.swift" -o "$scratch/benchmark"
for run in 1 2 3; do
  printf 'Run %s; snapshot SHA-256 %s\n' "$run" "$expected"
  "$scratch/benchmark" --disconnect
done
