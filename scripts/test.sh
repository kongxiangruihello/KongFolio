#!/bin/bash
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
mkdir -p "$ROOT/.build/smoke"
export CLANG_MODULE_CACHE_PATH="$ROOT/.build/clang-cache"
python3 - "$ROOT" <<'PY'
import pathlib,sys
root=pathlib.Path(sys.argv[1])
tests='\n'.join(p.read_text() for p in sorted((root/'Tests/KongFolioTests').glob('*.swift'))).replace('import XCTest','').replace('@testable import KongFolio','')
shim='''
class XCTestCase {}
func XCTAssertTrue(_ value: Bool, file: StaticString = #file, line: UInt = #line) { precondition(value, "Assertion failed at \\(file):\\(line)") }
func XCTAssertEqual<T: Equatable>(_ a: T, _ b: T, file: StaticString = #file, line: UInt = #line) { precondition(a == b, "Expected \\(a) == \\(b) at \\(file):\\(line)") }
func XCTAssertEqual(_ a: Double, _ b: Double, accuracy: Double) { precondition(abs(a-b) <= accuracy) }
func XCTAssertThrowsError<T>(_ action: @autoclosure () throws -> T) { do { _ = try action(); fatalError("Expected error") } catch {} }
@main struct SmokeRunner {
    @MainActor static func main() async throws {
        let suite = DocumentServicesTests()
        try suite.testSubsetOrderAndIsolation()
        try suite.testImageAdjustmentGeometryAndExport()
        try suite.testSearchableLayerSurvivesSaveAndRotation()
        try suite.testVisionRecognizesRasterText()
        try suite.testAnnotationsSurvivePDFExport()
        suite.testInvalidImportFails()
        try suite.testPageEditsUndoRedo()
        let v2 = VersionTwoTests()
        try v2.testPageRanges()
        try v2.testMultiSelectionAndRecipeRemapping()
        try v2.testProjectRoundTripAndRecovery()
        try v2.testNonDestructiveImageAndCrop()
        try v2.testPerspectiveAndCropGeometry()
        try v2.testAnnotationEditAndUndo()
        try v2.testDetectPaper()
        try v2.testSignatureLibraryRoundTrip()
        try v2.testOCRPreservesRotatedCroppedVisualContent()
        try v2.testBatchAndCompressionOutputs()
        try await v2.testCancelLeavesNoPartialExport()
        let v3 = VersionThreeTests()
        v3.testMouseCropGeometry()
        try v3.testComposedCropAndUndo()
        try v3.testProjectMigrationAndReadingRemapping()
        try v3.testSearchOutlineAndNotes()
        try v3.testConfiguredExportDimensionsAndMetadata()
        try await v3.testConfiguredBatchCancellation()
        try v3.testOCRReviewAndReRecognition()
        try v3.testImportPreservesOutline()
        print("PASS: 26 core integration tests")
    }
}
'''
(root/'.build/smoke/Runner.swift').write_text(tests+shim)
PY
swiftc -swift-version 5 -parse-as-library "$ROOT/Sources/KongFolio/DocumentServices.swift" "$ROOT/Sources/KongFolio/Workspace.swift" "$ROOT/Sources/KongFolio/ProjectStore.swift" "$ROOT/Sources/KongFolio/BackgroundJobs.swift" "$ROOT/Sources/KongFolio/AnnotationEditing.swift" "$ROOT/Sources/KongFolio/ReadingServices.swift" "$ROOT/Sources/KongFolio/ExportServices.swift" "$ROOT/Sources/KongFolio/ImportServices.swift" "$ROOT/Sources/KongFolio/CropGeometry.swift" "$ROOT/.build/smoke/Runner.swift" -o "$ROOT/.build/smoke/KongFolioTests"
"$ROOT/.build/smoke/KongFolioTests"
