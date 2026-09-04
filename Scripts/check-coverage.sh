#!/usr/bin/env bash

set -euo pipefail

minimum="${1:-90.0}"
output="${2:-coverage.lcov}"
profile="$(find .build -path '*/debug/codecov/default.profdata' -print -quit)"
binary="$(find .build -type f -path '*.xctest/Contents/MacOS/*PackageTests' -perm -111 -print -quit)"

if [[ -z "${profile}" || -z "${binary}" ]]; then
  echo "::error::Swift coverage profile or test binary was not found"
  exit 1
fi

report="$(xcrun llvm-cov report "${binary}" \
  -instr-profile="${profile}" \
  -ignore-filename-regex='(.build|Tests)/' \
  Sources/LuxoClient Sources/LuxoCompiler)"
printf '%s\n' "${report}"

coverage="$(awk '/^TOTAL/ { gsub("%", "", $10); print $10 }' <<<"${report}")"
if [[ -z "${coverage}" ]]; then
  echo "::error::Unable to read total line coverage"
  exit 1
fi

if ! awk -v actual="${coverage}" -v required="${minimum}" \
  'BEGIN { exit !(actual + 0 >= required + 0) }'; then
  echo "::error::Source line coverage ${coverage}% is below ${minimum}%"
  exit 1
fi

xcrun llvm-cov export "${binary}" \
  -instr-profile="${profile}" \
  -format=lcov \
  -ignore-filename-regex='(.build|Tests)/' \
  Sources/LuxoClient Sources/LuxoCompiler >"${output}"

echo "Source line coverage ${coverage}% meets ${minimum}%"
