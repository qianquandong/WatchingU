#!/bin/sh
set -eu
cd "$(dirname "$0")/.."
sh Scripts/check_rules.sh
swift test
xcodebuild -project DayTape.xcodeproj -scheme DayTape -destination 'generic/platform=iOS Simulator' CODE_SIGNING_ALLOWED=NO build
xcodebuild -project DayTape.xcodeproj -scheme DayTapeWatch -destination 'generic/platform=watchOS Simulator' CODE_SIGNING_ALLOWED=NO build
