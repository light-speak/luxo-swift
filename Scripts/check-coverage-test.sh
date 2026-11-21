#!/usr/bin/env bash

set -euo pipefail
umask 077

project="$(cd "$(dirname "$0")/.." && pwd)"
mkdir -p "${project}/.tmp"
fixture="$(mktemp -d "${project}/.tmp/coverage-script.XXXXXX")"
trap 'rm -rf -- "${fixture}"' EXIT
cd "${fixture}"

# Mock only llvm-cov; exercise the real artifact discovery and coverage gate.
function xcrun() {
  [[ "$1" == llvm-cov && "$3" == .build/test/debug/Fixture.xctest/Contents/MacOS/FixturePackageTests ]] || return 9
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
symbols=.build/test/debug/Fixture.xctest/Contents/MacOS/FixturePackageTests.dSYM/Contents/Resources/DWARF/FixturePackageTests
mkdir -p "$(dirname "${profile}")" "$(dirname "${release}")"
touch "${profile}" "${release}"
chmod +x "${release}"

if bash "${project}/Scripts/check-coverage.sh" 90 coverage.lcov > missing.log 2>&1; then
  echo 'Release-only artifacts must not pass the debug coverage gate' >&2
  exit 1
fi
grep -q 'test binary was not found' missing.log

mkdir -p "$(dirname "${symbols}")"
touch "${symbols}"
chmod a+x "${symbols}"
if bash "${project}/Scripts/check-coverage.sh" 90 coverage.lcov > symbols.log 2>&1 ||
  ! grep -q 'test binary was not found' symbols.log; then
  echo 'A dSYM symbol file must not be selected as the test executable' >&2
  exit 1
fi

mkdir -p "$(dirname "${debug}")"
touch "${debug}"
chmod u+x "${debug}"
bash "${project}/Scripts/check-coverage.sh" 90 coverage.lcov > mixed.log 2>&1
grep -q 'Source line coverage 100% meets 90%' mixed.log
grep -q 'TN:coverage-script-regression' coverage.lcov
echo 'Coverage artifact selection regression passed'
