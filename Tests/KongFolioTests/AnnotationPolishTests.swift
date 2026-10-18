import AppKit
import PDFKit
import XCTest
@testable import KongFolio

final class AnnotationPolishTests: XCTestCase {
    private func note(_ quote: String, kind: String = "批注", page: Int = 0, color: String? = nil) -> AnnotationNote {
        AnnotationNote(page: page, index: 0, kind: kind, quote: quote, note: "", colorName: color)
    }

    func testSearchTreatsTraditionalAndSimplifiedAlike() {
        var filter = AnnotationFilter()
        filter.text = "国家"
        XCTAssertTrue(filter.matches(note("華夏之國家")))
        filter.text = "學問"
        XCTAssertTrue(filter.matches(note("学问之道")))
        filter.text = "為"
        XCTAssertTrue(filter.matches(note("无为而治")))
        filter.text = "羣"
        XCTAssertTrue(filter.matches(note("人群")))
        filter.text = "不存在"
        XCTAssertFalse(filter.matches(note("人群")))
    }

    func testSearchCoversKindColourAndPage() {
        var filter = AnnotationFilter()
        filter.text = "第 3 页"
        XCTAssertTrue(filter.matches(note("x", page: 2)))
        XCTAssertFalse(filter.matches(note("x", page: 3)))
        filter.text = "手写"
        XCTAssertTrue(filter.matches(note("", kind: "手写")))
    }

    func testPresetsRoundTripThroughDefaults() {
        let suite = UserDefaults(suiteName: "kongfolio-presets-" + UUID().uuidString)!
        let preset = AnnotationPreset(name: "我的样式", rgb: [0.1, 0.2, 0.3], width: 4, dashed: true)
        AnnotationPresets.saveUser([preset], suite)
        XCTAssertEqual(AnnotationPresets.loadUser(suite), [preset])
    }

    func testFreshNamesDoNotCollide() {
        let first = AnnotationPreset(name: "我的样式", rgb: [0, 0, 0], width: 2)
        XCTAssertEqual(AnnotationPresets.freshName("我的样式", among: [first]), "我的样式 2")
        XCTAssertEqual(AnnotationPresets.freshName("红色细线", among: []), "红色细线 2")
        XCTAssertEqual(AnnotationPresets.freshName("  ", among: []), "我的样式")
    }

    func testRecolouringKeepsTransparency() {
        let marker = PDFAnnotation(bounds: CGRect(x: 0, y: 0, width: 50, height: 10), forType: .ink, withProperties: nil)
        marker.color = NSColor.yellow.withAlphaComponent(0.4)
        AnnotationRecolor.apply(marker, color: .blue)
        XCTAssertEqual(marker.color.alphaComponent, 0.4, accuracy: 0.01)
        let line = PDFAnnotation(bounds: CGRect(x: 0, y: 0, width: 50, height: 10), forType: .line, withProperties: nil)
        line.color = .red
        AnnotationRecolor.apply(line, color: .green)
        XCTAssertEqual(line.color.alphaComponent, 1, accuracy: 0.01)
        XCTAssertTrue(line.color.greenComponent > 0.5)
    }

    @MainActor func testApplyingAPresetSetsStyle() {
        let space = Workspace(storage: FileManager.default.temporaryDirectory.appendingPathComponent("kongfolio-" + UUID().uuidString, isDirectory: true))
        let dashed = AnnotationPresets.builtIn[2]
        space.apply(dashed)
        XCTAssertTrue(space.lineDashed)
        XCTAssertEqual(space.penWidth, 2, accuracy: 0.001)
        let marker = AnnotationPresets.builtIn[4]
        space.apply(marker)
        XCTAssertTrue(space.penHighlighter)
        XCTAssertEqual(space.tool, AnnotationTool.pen)
    }
}
