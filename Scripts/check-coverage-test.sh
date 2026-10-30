#!/usr/bin/env bash

set -euo pipefail

project="$(cd "$(dirname "$0")/.." && pwd)"
mkdir -p "${project}/.tmp"
fixture="$(mktemp -d "${project}/.tmp/coverage-script.XXXXXX")"
trap 'rm -rf -- "${fixture}"' EXIT
cd "${fixture}"

# Mock only llvm-cov; exercise the real artifact discovery and coverage gate.
function xcrun() {
  [[ "$1" == llvm-cov && "$3" == */debug/*.xctest/Contents/MacOS/*PackageTests ]] || return 9
  [[ " $* " == *" Sources/LuxoNIO "* ]] || return 9
  case "$2" in
    report) printf '%s\n' 'TOTAL 1 0 100% 1 0 100% 1 0 100%' ;;
    export) printf '%s\n' 'TN:coverage-script-regression' ;;
    *) return 9 ;;
  esac
}
export -f xcrun

profile=.build/test/debug/codecov/default.profdata
release=.build/test/release/Fixture.xctest/Contents/MacOS/FixturePackageTests
debug=.build/test/debug/Fixture.xctest/Contents/MacOS/FixturePackageTests
mkdir -p "$(dirname "${profile}")" "$(dirname "${release}")"
touch "${profile}" "${release}"
chmod +x "${release}"

if bash "${project}/Scripts/check-coverage.sh" 90 coverage.lcov > missing.log 2>&1; then
  echo 'Release-only artifacts must not pass the debug coverage gate' >&2
  exit 1
fi
grep -q 'test binary was not found' missing.log

mkdir -p "$(dirname "${debug}")"
touch "${debug}"
chmod +x "${debug}"
bash "${project}/Scripts/check-coverage.sh" 90 coverage.lcov > mixed.log 2>&1
grep -q 'Source line coverage 100% meets 90%' mixed.log
grep -q 'TN:coverage-script-regression' coverage.lcov
echo 'Coverage artifact selection regression passed'
