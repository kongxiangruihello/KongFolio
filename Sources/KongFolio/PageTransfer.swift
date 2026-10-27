import Foundation
import PDFKit

struct PageDrag: Codable {
    var source: UUID
    var revision: UUID
    var pages: [Int]
    static let prefix = "KongFolioPages:"
    var text: String { Self.prefix + ((try? JSONEncoder().encode(self).base64EncodedString()) ?? "") }
    static func decode(_ text: String) -> Self? {
        guard text.hasPrefix(prefix), let data = Data(base64Encoded: String(text.dropFirst(prefix.count))), data.count < 1_000_000 else { return nil }
        return try? JSONDecoder().decode(Self.self, from: data)
    }
}

struct PageTransferRequest: Identifiable {
    let id = UUID()
    var drag: PageDrag
    var target: UUID
    var targetRevision: UUID
    var insertion: Int
}

extension Workspace {
    func pageDrag(_ index: Int) -> String {
        PageDrag(source: id, revision: revision, pages: selectedPages.contains(index) ? effectivePages : [index]).text
    }
    @discardableResult func receivePageDrag(_ value: String, before index: Int) -> Bool {
        guard let drag = PageDrag.decode(value), !busy, placingSignature == nil else { return false }
        if drag.source == id {
            guard drag.revision == revision, let first = drag.pages.first else { return false }
            movePages(before: index, dragged: first); return true
        }
        return store?.preparePageTransfer(drag, to: self, at: index) ?? false
    }
}

extension WorkspaceStore {
    @discardableResult func preparePageTransfer(_ drag: PageDrag, to target: Workspace, at index: Int) -> Bool {
        guard let source = tabs.compactMap(\.workspace).first(where: { $0.id == drag.source }), source !== target,
              !source.busy, !target.busy, source.placingSignature == nil, target.placingSignature == nil,
              source.revision == drag.revision, !drag.pages.isEmpty,
              Set(drag.pages).count == drag.pages.count, drag.pages.allSatisfy({ (0..<source.count).contains($0) }),
              (0...target.count).contains(index) else { return false }
        pendingPageTransfer = PageTransferRequest(drag: drag, target: target.id, targetRevision: target.revision, insertion: index)
        return true
    }
    @discardableResult func transferPages(_ request: PageTransferRequest, move: Bool, insertion: Int? = nil) -> Bool {
        guard let source = tabs.compactMap(\.workspace).first(where: { $0.id == request.drag.source }),
              let target = tabs.compactMap(\.workspace).first(where: { $0.id == request.target }), source !== target,
              !source.busy, !target.busy, source.placingSignature == nil, target.placingSignature == nil,
              source.revision == request.drag.revision, target.revision == request.targetRevision else {
            activeWorkspace?.error = "文档在拖动后发生变化，请重新拖动页面。"; return false
        }
        let pages = request.drag.pages.sorted(), at = insertion ?? request.insertion
        guard !pages.isEmpty, Set(pages).count == pages.count, pages.allSatisfy({ (0..<source.count).contains($0) }), (0...target.count).contains(at),
              !move || pages.count < source.count else {
            target.error = "源文档至少保留一页；请改为复制或减少移动页数。"; return false
        }
        do {
            // Prepare both new states and undo records before changing either document.
            let sourceBefore = try source.snapshot(), targetBefore = try target.snapshot()
            let inserted = try PDFDocument(data: DocumentServices.subset(source.document, indexes: pages).dataRepresentation().unwrap("无法复制源页面")).unwrap("无法读取源页面")
            let output = try PDFDocument(data: targetBefore.pdf).unwrap("无法读取目标文档")
            for offset in pages.indices { output.insert(try inserted.page(at: offset).unwrap("源页面缺失"), at: at + offset) }
            let selected = Set(pages)
            var sourceAfter = sourceBefore
            if move {
                let keep = (0..<source.count).filter { !selected.contains($0) }
                sourceAfter = try PageTransferArchive.subset(sourceBefore, pages: keep)
            }
            var targetAfter = targetBefore
            targetAfter.pdf = try output.dataRepresentation().unwrap("无法生成目标文档")
            targetAfter.selection = at; targetAfter.selectedPages = Set(at..<(at + pages.count)); targetAfter.dirty = true
            targetAfter.reading?.bookmarks = (targetBefore.reading?.bookmarks ?? []).map { var x = $0; if x.page >= at { x.page += pages.count }; return x }
            targetAfter.reading?.outline = (targetBefore.reading?.outline ?? []).map { var x = $0; if x.page >= at { x.page += pages.count }; return x }
            for (offset, old) in pages.enumerated() {
                targetAfter.reading?.bookmarks += (sourceBefore.reading?.bookmarks ?? []).filter { $0.page == old }.map { var x = $0; x.id = UUID(); x.page = at + offset; return x }
                targetAfter.reading?.outline += (sourceBefore.reading?.outline ?? []).filter { $0.page == old }.map { var x = $0; x.id = UUID(); x.page = at + offset; return x }
            }
            targetAfter.ocrOriginals = PageTransferArchive.insert(targetBefore.ocrOriginals ?? [:], incoming: sourceBefore.ocrOriginals ?? [:], pages: pages, at: at)
            targetAfter.ocrRegions = PageTransferArchive.insert(targetBefore.ocrRegions ?? [:], incoming: sourceBefore.ocrRegions ?? [:], pages: pages, at: at)
            targetAfter.signatureEdits = PageTransferArchive.insert(targetBefore.signatureEdits ?? [:], incoming: sourceBefore.signatureEdits ?? [:], pages: pages, at: at)
            try targetAfter.validate(); try sourceAfter.validate()
            try target.restore(targetAfter, keepProjectURL: true)
            target.pushUndo(.snapshot(targetBefore)); target.changed()
            if move { try source.restore(sourceAfter, keepProjectURL: true); source.pushUndo(.snapshot(sourceBefore)); source.changed() }
            select(target.id)
            target.status = "已\(move ? "移动" : "复制") \(pages.count) 页；\(move ? "两份文档可分别撤销" : "⌘Z 可撤销")"
            pendingPageTransfer = nil
            return true
        } catch { target.error = "页面传送失败：" + error.localizedDescription; return false }
    }
}

enum PageTransferArchive {
    static func insert<T>(_ original: [Int: T], incoming: [Int: T], pages: [Int], at: Int) -> [Int: T] {
        var result: [Int: T] = [:]
        for (index, value) in original { result[index >= at ? index + pages.count : index] = value }
        for (offset, index) in pages.enumerated() { result[at + offset] = incoming[index] }
        return result
    }
    static func subset(_ archive: ProjectArchive, pages: [Int]) throws -> ProjectArchive {
        var result = archive
        let document = try PDFDocument(data: archive.pdf).unwrap("无法读取源文档")
        result.pdf = try DocumentServices.subset(document, indexes: pages).dataRepresentation().unwrap("无法整理源文档")
        result.selection = min(archive.selection, max(0, pages.count - 1)); result.selectedPages = [result.selection]; result.dirty = true
        result.ocrOriginals = [:]; result.ocrRegions = [:]; result.signatureEdits = [:]
        result.reading?.bookmarks = []; result.reading?.outline = []
        result.recipes = [:]; result.drafts = [:]
        for (index, old) in pages.enumerated() {
            result.ocrOriginals?[index] = archive.ocrOriginals?[old]; result.ocrRegions?[index] = archive.ocrRegions?[old]
            result.signatureEdits?[index] = archive.signatureEdits?[old]
            result.reading?.bookmarks += (archive.reading?.bookmarks ?? []).filter { $0.page == old }.map { var x = $0; x.page = index; return x }
            result.reading?.outline += (archive.reading?.outline ?? []).filter { $0.page == old }.map { var x = $0; x.page = index; return x }
        }
        return result
    }
}
