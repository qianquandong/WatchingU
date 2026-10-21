#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."

if [[ "$(uname -s)" != Darwin ]]; then
  printf '%s\n' 'Native CI requires a macOS host with full Xcode.' >&2
  exit 1
fi

mkdir -p artifacts
failed=0

run_logged() {
  local label="$1"
  shift
  printf '\n%s\n' "Running ${label}"
  if "$@" 2>&1 | tee "artifacts/${label}.log"; then
    printf '%s\n' "PASS ${label}" >> artifacts/summary.txt
  else
    printf '%s\n' "FAIL ${label}" >> artifacts/summary.txt
    failed=1
  fi
}

run_logged toolchain xcodebuild -version
run_logged sdks xcodebuild -showsdks
run_logged rules sh Scripts/check_rules.sh
run_logged storage-tests swift test --xunit-output artifacts/swift-tests.xml

# Generic simulator destinations compile without booting devices or requiring
# a signing identity. Real paired Watch delivery still needs device testing.
run_logged iphone-build xcodebuild \
  -project DayTape.xcodeproj \
  -scheme DayTape \
  -configuration Debug \
  -destination 'generic/platform=iOS Simulator' \
  -derivedDataPath .build/DerivedData-iPhone \
  -clonedSourcePackagesDirPath .build/SourcePackages \
  -resultBundlePath artifacts/iphone-build.xcresult \
  CODE_SIGNING_ALLOWED=NO \
  build

run_logged watch-build xcodebuild \
  -project DayTape.xcodeproj \
  -scheme DayTapeWatch \
  -configuration Debug \
  -destination 'generic/platform=watchOS Simulator' \
  -derivedDataPath .build/DerivedData-Watch \
  -clonedSourcePackagesDirPath .build/SourcePackages \
  -resultBundlePath artifacts/watch-build.xcresult \
  CODE_SIGNING_ALLOWED=NO \
  build

cat artifacts/summary.txt
exit "$failed"
