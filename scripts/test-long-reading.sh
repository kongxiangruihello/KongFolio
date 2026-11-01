#!/bin/bash
# Run after swift test. Uses the built XCTest bundle directly so packaging can continue concurrently.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
BIN="$(swift build --package-path "$ROOT" --disable-sandbox --build-system native --show-bin-path)"
export KONGFOLIO_LONG_INPUT_SECONDS="${KONGFOLIO_LONG_INPUT_SECONDS:-600}"
export KONGFOLIO_LONG_INPUT_REPORT="${KONGFOLIO_LONG_INPUT_REPORT:-$ROOT/.build/long-reading-report.json}"
xcrun xctest -XCTest 'KongFolioTests.Release044Tests/testSustainedChineseEditingAcrossRecordSwitches' "$BIN/KongFolioPackageTests.xctest"
