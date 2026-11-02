#!/bin/bash
# Normal production save/close paths, in independent storage; optional local corpus is never modified.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
mkdir -p "$ROOT/.build/reading-batch"
export CLANG_MODULE_CACHE_PATH="$ROOT/.build/clang-cache"
SOURCES=()
for file in "$ROOT"/Sources/KongFolio/*.swift; do
  if grep -qE '^(@main|struct [A-Za-z]+: View|struct [A-Za-z]+: NSViewRepresentable)' "$file"; then continue; fi
  SOURCES+=("$file")
done
for file in "$ROOT"/Sources/KongFolioUpdateKit/*.swift; do SOURCES+=("$file"); done
swiftc -swift-version 5 -whole-module-optimization -Onone -num-threads 4 -parse-as-library "${SOURCES[@]}" "$ROOT/Tests/Manual/ReadingBatchRunner.swift" -o "$ROOT/.build/reading-batch/KongFolioReadingBatchRunner"
"$ROOT/.build/reading-batch/KongFolioReadingBatchRunner"
