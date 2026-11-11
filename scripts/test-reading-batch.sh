#!/bin/bash
# Normal production save/close paths, in independent storage; optional local corpus is never modified.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
mkdir -p "$ROOT/.build/reading-batch"
export CLANG_MODULE_CACHE_PATH="$ROOT/.build/clang-cache"
SOURCES=()
# The reader and its views share symbols. Build the complete module, using the runner as its only entry point.
APP_SOURCE="$ROOT/.build/reading-batch/KongFolioApp.swift"
sed 's/^@main struct KongFolioApp/struct KongFolioApp/' "$ROOT/Sources/KongFolio/KongFolioApp.swift" > "$APP_SOURCE"
for file in "$ROOT"/Sources/KongFolio/*.swift; do
  if [[ "$file" == "$ROOT/Sources/KongFolio/KongFolioApp.swift" ]]; then continue; fi
  SOURCES+=("$file")
done
SOURCES+=("$APP_SOURCE")
for file in "$ROOT"/Sources/KongFolioUpdateKit/*.swift; do SOURCES+=("$file"); done
swiftc -swift-version 5 -O "$ROOT/Sources/KongFolioPDFProbe/main.swift" -o "$ROOT/.build/reading-batch/KongFolioPDFProbe"
swiftc -swift-version 5 -whole-module-optimization -Onone -num-threads 4 -parse-as-library "${SOURCES[@]}" "$ROOT/Tests/Manual/ReadingBatchRunner.swift" -o "$ROOT/.build/reading-batch/KongFolioReadingBatchRunner"
"$ROOT/.build/reading-batch/KongFolioReadingBatchRunner"
