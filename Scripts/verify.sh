#!/bin/zsh
set -euo pipefail
cd "${0:A:h:h}"
mkdir -p .work
swift test --scratch-path .work/swift-build 2>&1 | tee .work/swift-test.log
xcodebuild -project Velyn.xcodeproj -scheme Velyn \
  -destination 'generic/platform=iOS Simulator' \
  -derivedDataPath .work/DerivedData CODE_SIGNING_ALLOWED=NO build \
  > .work/xcode-build.log 2>&1
rg 'warning:|BUILD SUCCEEDED' .work/xcode-build.log
