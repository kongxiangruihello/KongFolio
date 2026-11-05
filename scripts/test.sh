#!/bin/bash
# Runs every model test using a small XCTest-free shim, then checks production autosave
# in a separately named process. SwiftPM's existing app objects avoid compiling models twice.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
mkdir -p "$ROOT/.build/smoke"
export CLANG_MODULE_CACHE_PATH="$ROOT/.build/clang-cache"
swift build --build-system native --disable-sandbox --package-path "$ROOT" --product KongFolio
swift build --build-system native --disable-sandbox --package-path "$ROOT" --product KongFolioPDFProbe
PROBE_BIN="$(swift build --build-system native --disable-sandbox --package-path "$ROOT" --show-bin-path)"
cp "$PROBE_BIN/KongFolioPDFProbe" "$ROOT/.build/smoke/KongFolioPDFProbe"

python3 - "$ROOT" <<'PY'
import pathlib, re, sys
root = pathlib.Path(sys.argv[1])
files = sorted((root / 'Tests/KongFolioTests').glob('*.swift'))
tests = '\n'.join(p.read_text() for p in files).replace('import XCTest', '').replace('@testable import KongFolio', '')
# Compile the normal-mode probe once with the model tests. A separately named process below
# still exercises production autosave detection, without a second full model compilation.
tests += '\n' + (root / 'Tests/Manual/AutosaveRunner.swift').read_text().replace('@main struct AutosaveRunner', 'enum NormalAutosaveProbe')
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
func XCTUnwrap<T>(_ value: T?, _ message: String = "", file: StaticString = #file, line: UInt = #line) throws -> T { guard let value else { preconditionFailure("Unexpectedly nil at \\(file):\\(line) \\(message)") }; return value }
func XCTAssertEqual<T: Equatable>(_ a: T, _ b: T, _ message: String = "", file: StaticString = #file, line: UInt = #line) { precondition(a == b, "Expected \\(a) == \\(b) at \\(file):\\(line) \\(message)") }
func XCTAssertEqual(_ a: Double, _ b: Double, accuracy: Double, file: StaticString = #file, line: UInt = #line) { precondition(abs(a - b) <= accuracy, "Expected \\(a) ≈ \\(b) at \\(file):\\(line)") }
func XCTAssertNil(_ value: Any?, _ message: String = "", file: StaticString = #file, line: UInt = #line) { precondition(value == nil, "Expected nil at \\(file):\\(line)") }
func XCTAssertNotNil(_ value: Any?, file: StaticString = #file, line: UInt = #line) { precondition(value != nil, "Expected non-nil at \\(file):\\(line)") }
func XCTAssertThrowsError<T>(_ action: @autoclosure () throws -> T, file: StaticString = #file, line: UInt = #line) { do { _ = try action(); fatalError("Expected error at \\(file):\\(line)") } catch {} }
@main struct SmokeRunner {
    @MainActor static func main() async throws {
        if CommandLine.arguments.contains("--normal-autosave") {
            try await NormalAutosaveProbe.main(); return
        }
''' + '\n'.join(calls) + f'''
        print("PASS: {count} integration tests")
    }}
}}
'''
(root / '.build/smoke/Runner.swift').write_text(tests + shim)
# SwiftPM exposes executable modules for tests and names the app entry point KongFolio_main.
# Linking its objects does not call that entry point or start the app.
runner = root / '.build/smoke/Runner.swift'
runner.write_text('@testable import KongFolio\nimport KongFolioUpdateKit\n' + runner.read_text())
PY
# The builds above establish that these objects and modules belong to the current source.
# All test methods still execute; neither XCTest nor the app's GUI entry point is invoked.
OBJECTS=("$PROBE_BIN"/KongFolio.build/*.o "$PROBE_BIN"/KongFolioUpdateKit.build/*.o)
swiftc -swift-version 5 -whole-module-optimization -Onone -num-threads 4 -parse-as-library -I "$PROBE_BIN/Modules" "$ROOT/.build/smoke/Runner.swift" "${OBJECTS[@]}" -o "$ROOT/.build/smoke/KongFolioTests"
"$ROOT/.build/smoke/KongFolioTests"
# Keep the existing CI entry point while checking timed autosave in a separate non-XCTest process.
export KONGFOLIO_AUTOSAVE_REPORT="${KONGFOLIO_AUTOSAVE_REPORT:-$ROOT/.build/autosave/report.json}"
mkdir -p "$ROOT/.build/autosave"
cp "$ROOT/.build/smoke/KongFolioTests" "$ROOT/.build/autosave/KongFolioAutosaveRunner"
cp "$ROOT/.build/smoke/KongFolioPDFProbe" "$ROOT/.build/autosave/KongFolioPDFProbe"
"$ROOT/.build/autosave/KongFolioAutosaveRunner" --normal-autosave
