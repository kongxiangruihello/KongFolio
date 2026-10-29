import Foundation
import PDFKit

struct PageReassociation: Identifiable {
    var id: Int { old }
    var old: Int
    var proposed: Int?
    var confidence: Double
    var reason: String
}
enum ReadingReassociation {
    static func propose(old: Data, new: Data) throws -> [PageReassociation] {
        let a = try PDFDocument(data: old).unwrap("旧版本无法读取"), b = try PDFDocument(data: new).unwrap("新版本无法读取")
        func fingerprint(_ page: PDFPage) -> (String, Set<String>) {
            let text = AnnotationFilter.folded(page.string ?? "").filter { !$0.isWhitespace }
            let chars = Array(text); var grams = Set<String>()
            if chars.count >= 3 { for i in stride(from: 0, through: chars.count-3, by: 3) { grams.insert(String(chars[i..<min(i+8,chars.count)])) } }
            return (text, grams)
        }
        let targets = (0..<b.pageCount).compactMap { b.page(at: $0).map(fingerprint) }
        var result: [PageReassociation] = []
        for i in 0..<a.pageCount {
            try Task.checkCancellation(); let source = fingerprint(a.page(at: i)!)
            guard source.0.count >= 15 else { result.append(PageReassociation(old: i, confidence: 0, reason: "扫描页或文字不足，请人工指定")); continue }
            let scores = targets.enumerated().map { j, target -> (Int,Double) in
                if source.0 == target.0 { return (j,1) }
                let union = source.1.union(target.1).count
                return (j,union == 0 ? 0 : Double(source.1.intersection(target.1).count)/Double(union))
            }.sorted { $0.1 > $1.1 }
            let best = scores.first, next = scores.dropFirst().first?.1 ?? 0
            let reliable = (best?.1 ?? 0) >= 0.65 && (best?.1 ?? 0) - next >= 0.1
            result.append(PageReassociation(old: i, proposed: reliable ? best?.0 : nil, confidence: best?.1 ?? 0, reason: reliable ? "正文匹配，请核对" : "匹配不唯一或差异较大，请人工指定"))
        }
        return result
    }
    /// Transfer only explicitly confirmed anchors. Page annotations are copied, never silently overlaid.
    static func apply(_ old: ProjectArchive, to bytes: Data, mapping: [Int: Int], includeAnnotations: Bool) throws -> ProjectArchive {
        let original = try PDFDocument(data: old.pdf).unwrap("旧版本无法读取"), target = try PDFDocument(data: bytes).unwrap("新版本无法读取")
        guard !mapping.isEmpty, mapping.keys.allSatisfy({ (0..<original.pageCount).contains($0) }), mapping.values.allSatisfy({ (0..<target.pageCount).contains($0) }), Set(mapping.values).count == mapping.count else { throw FolioError(message: "页面对应重复或越界") }
        if includeAnnotations {
            for (oldIndex,newIndex) in mapping {
                let source = original.page(at: oldIndex)!, destination = target.page(at: newIndex)!
                guard source.bounds(for: .cropBox).size == destination.bounds(for: .cropBox).size else { throw FolioError(message: "页面尺寸不同，不能直接迁移标注，请先校准") }
                for mark in Workspace.visibleAnnotations(on: source) { if let copy = mark.copy() as? PDFAnnotation { destination.addAnnotation(copy) } }
            }
        }
        var result = old
        result.pdf = try withExtendedLifetime(original) { try target.dataRepresentation().unwrap("新版本生成失败") }
        result.sourcePath = nil; result.projectPath = nil; result.fileBaseline = nil
        result.reading?.bookmarks = old.reading?.bookmarks.compactMap { value in guard let page = mapping[value.page] else { return nil }; var value = value; value.page = page; return value } ?? []
        result.reading?.outline = old.reading?.outline.compactMap { value in guard let page = mapping[value.page] else { return nil }; var value = value; value.page = page; return value } ?? []
        // OCR crops/signature source layers are tied to exact pixels and deliberately stay in the old archive.
        result.ocrOriginals = nil; result.ocrRegions = nil; result.signatureEdits = nil; result.wordDraft = nil; result.tableDrafts = nil
        result.selection = mapping[old.selection] ?? 0; result.selectedPages = [result.selection]; result.dirty = true
        try result.validate(); return result
    }
}
