#!/bin/bash
# Timed autosave must be tested without importing XCTest or using the test-run process name.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
mkdir -p "$ROOT/.build/autosave"
export CLANG_MODULE_CACHE_PATH="$ROOT/.build/clang-cache"
SOURCES=()
for file in "$ROOT"/Sources/KongFolio/*.swift; do
  if grep -qE '^(@main|struct [A-Za-z]+: View|struct [A-Za-z]+: NSViewRepresentable)' "$file"; then continue; fi
  SOURCES+=("$file")
done
for file in "$ROOT"/Sources/KongFolioUpdateKit/*.swift; do SOURCES+=("$file"); done
swiftc -swift-version 5 -parse-as-library "${SOURCES[@]}" "$ROOT/Tests/Manual/AutosaveRunner.swift" -o "$ROOT/.build/autosave/KongFolioAutosaveRunner"
"$ROOT/.build/autosave/KongFolioAutosaveRunner"
