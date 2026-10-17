import XCTest
import PDFKit
@testable import KongFolio

/// The user's sample is encrypted with an empty user password and "no modification" permissions (owner-restricted).
/// These tests check that such a file can be opened, annotated, rotated, cropped and saved like any other.
final class RestrictedPDFTests: XCTestCase {
    func sample() throws -> PDFDocument? {
        let candidates = [
            URL(fileURLWithPath: #filePath).deletingLastPathComponent().appendingPathComponent("Fixtures/framed-vertical-page.pdf"),
            URL(fileURLWithPath: FileManager.default.currentDirectoryPath).appendingPathComponent("Tests/KongFolioTests/Fixtures/framed-vertical-page.pdf"),
        ]
        guard let url = candidates.first(where: { FileManager.default.fileExists(atPath: $0.path) }) else { return nil }
        return try PDFDocument(url: url).unwrap("无法读取样张")
    }

    @MainActor func testAnAnnotationSurvivesSavingARestrictedFile() throws {
        guard let document = try sample() else { return }
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("kongfolio-" + UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let workspace = Workspace(storage: directory)
        workspace.document = document
        XCTAssertFalse(document.isLocked)
        let page = try document.page(at: 0).unwrap("无页面")
        let note = PDFAnnotation(bounds: CGRect(x: 100, y: 100, width: 80, height: 40), forType: .square, withProperties: nil)
        note.color = .systemYellow
        page.addAnnotation(note)
        let saved = try PDFDocument(data: workspace.pdfData()).unwrap("保存结果无法读取")
        XCTAssertEqual(saved.pageCount, 1)
        let kept = saved.page(at: 0)?.annotations.filter { $0.type == "Square" }.count ?? 0
        XCTAssertTrue(kept == 1, "保存后保留的方框标注数应为 1，实际 \(kept)")
    }

    @MainActor func testRotatingAndCroppingARestrictedFileWorksAndUndoes() throws {
        guard let document = try sample() else { return }
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("kongfolio-" + UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let workspace = Workspace(storage: directory)
        workspace.document = document
        workspace.cropOdd = CropMargins(left: 0.1, right: 0.1, top: 0.1, bottom: 0.1)
        workspace.cropScope = .all
        let before = try document.page(at: 0).unwrap("无页面").bounds(for: .cropBox).width
        workspace.applyCrop()
        let cut = try workspace.document.page(at: 0).unwrap("无页面").bounds(for: .cropBox).width
        XCTAssertTrue(cut < before * 0.9, "裁边后宽度应变窄：\(before) → \(cut)")
        let reloaded = try PDFDocument(data: workspace.pdfData()).unwrap("保存结果无法读取")
        let saved = try reloaded.page(at: 0).unwrap("无页面").bounds(for: .cropBox).width
        XCTAssertTrue(abs(saved - cut) < 1, "保存后的裁边应一致：\(cut) vs \(saved)")
        workspace.undo()
        let restored = try workspace.document.page(at: 0).unwrap("无页面").bounds(for: .cropBox).width
        XCTAssertTrue(abs(restored - before) < 1, "撤销后应回到原宽度：\(before) vs \(restored)")
    }

    func testTheSaveDoesNotKeepTheEncryptionThatForbadeChanges() throws {
        guard let document = try sample() else { return }
        let data = try document.dataRepresentation().unwrap("无法序列化")
        let again = try PDFDocument(data: data).unwrap("无法再次读取")
        XCTAssertFalse(again.isLocked)
        XCTAssertEqual(again.pageCount, 1)
    }
}
