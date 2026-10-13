#!/bin/bash
# Runs the XCTest suites without full Xcode: test files are compiled together with the
# non-UI sources and a tiny XCTest shim. Test methods are discovered automatically.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
mkdir -p "$ROOT/.build/smoke"
export CLANG_MODULE_CACHE_PATH="$ROOT/.build/clang-cache"
python3 - "$ROOT" <<'PY'
import pathlib, re, sys
root = pathlib.Path(sys.argv[1])
files = sorted((root / 'Tests/KongFolioTests').glob('*.swift'))
tests = '\n'.join(p.read_text() for p in files).replace('import XCTest', '').replace('@testable import KongFolio', '')
calls, count = [], 0
for p in files:
    text = p.read_text()
    for cls in re.finditer(r'final class (\w+): XCTestCase \{', text):
        name = cls.group(1)
        body = text[cls.end():]
        nxt = re.search(r'\n(final class|class|actor|struct|enum) ', body)
        body = body[:nxt.start()] if nxt else body
        calls.append(f'        let {name.lower()} = {name}()')
        for m in re.finditer(r'func (test\w+)\(\)\s*(async)?\s*(throws)?', body):
            fn, is_async, throws = m.group(1), m.group(2), m.group(3)
            prefix = ('try ' if throws else '') + ('await ' if is_async else '')
            calls.append(f'        print("…", "{name}.{fn}"); {prefix}{name.lower()}.{fn}(); print("ok", "{name}.{fn}")')
            count += 1
shim = '''
class XCTestCase {}
func XCTAssertTrue(_ value: Bool, _ message: String = "", file: StaticString = #file, line: UInt = #line) { precondition(value, "Assertion failed at \\(file):\\(line) \\(message)") }
func XCTAssertFalse(_ value: Bool, _ message: String = "", file: StaticString = #file, line: UInt = #line) { precondition(!value, "Assertion failed at \\(file):\\(line) \\(message)") }
func XCTAssertEqual<T: Equatable>(_ a: T, _ b: T, _ message: String = "", file: StaticString = #file, line: UInt = #line) { precondition(a == b, "Expected \\(a) == \\(b) at \\(file):\\(line) \\(message)") }
func XCTAssertEqual(_ a: Double, _ b: Double, accuracy: Double, file: StaticString = #file, line: UInt = #line) { precondition(abs(a - b) <= accuracy, "Expected \\(a) ≈ \\(b) at \\(file):\\(line)") }
func XCTAssertNil(_ value: Any?, file: StaticString = #file, line: UInt = #line) { precondition(value == nil, "Expected nil at \\(file):\\(line)") }
func XCTAssertNotNil(_ value: Any?, file: StaticString = #file, line: UInt = #line) { precondition(value != nil, "Expected non-nil at \\(file):\\(line)") }
func XCTAssertThrowsError<T>(_ action: @autoclosure () throws -> T, file: StaticString = #file, line: UInt = #line) { do { _ = try action(); fatalError("Expected error at \\(file):\\(line)") } catch {} }
@main struct SmokeRunner {
    @MainActor static func main() async throws {
''' + '\n'.join(calls) + f'''
        print("PASS: {count} integration tests")
    }}
}}
'''
(root / '.build/smoke/Runner.swift').write_text(tests + shim)
PY
SOURCES=()
for file in "$ROOT"/Sources/KongFolio/*.swift; do
  # SwiftUI views and the app entry point are compiled by `swift build`; the runner only needs the model and services.
  if grep -qE '^(@main|struct [A-Za-z]+: View|struct [A-Za-z]+: NSViewRepresentable)' "$file"; then continue; fi
  SOURCES+=("$file")
done
swiftc -swift-version 5 -parse-as-library "${SOURCES[@]}" "$ROOT/.build/smoke/Runner.swift" -o "$ROOT/.build/smoke/KongFolioTests"
"$ROOT/.build/smoke/KongFolioTests"
