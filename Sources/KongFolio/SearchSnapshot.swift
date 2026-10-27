import Foundation
import AppKit
import PDFKit

/// Immutable search inputs, captured on the UI thread; workers never touch the editing models.
struct SearchSnapshot {
    var id: UUID
    var title: String
    var path: URL?
    var revision: UUID?
    var pdf: Data?
    var text: String?
    var card: BoardCard?
    var fingerprint: String { text.map { OCRPageCache.digest(Data($0.utf8)) } ?? card.map(Self.cardDigest) ?? "" }
    static func cardDigest(_ card: BoardCard) -> String { let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]; return (try? encoder.encode(card)).map(OCRPageCache.digest) ?? "" }
    func search(query: String, limit: Int, terms: FolderSearchTerms, includeAnnotations: Bool, cache: inout [String: String]) throws -> FolderSearchFile {
        let url = path ?? URL(fileURLWithPath: "/未保存/" + id.uuidString + "/" + title)
        var result = FolderSearchFile(url: url)
        func add(_ page: FolderSearchPage, category: String) {
            guard terms.accepts(page.text, cache: &cache) else { return }
            result.hits += FolderSearchService.matches(page, query: query, limit: max(0, limit - result.hits.count), cache: &cache).map {
                FolderSearchHit(url: url, relativePath: title + (path == nil ? "（未保存）" : " · 当前编辑"), fingerprint: fingerprint, query: query, hit: $0, category: category, tabID: card == nil ? id : nil, revision: revision, cardID: card?.id, sourceRect: page.sourceRect)
            }
        }
        if let pdf {
            let document = try PDFDocument(data: pdf).unwrap("无法搜索当前 PDF")
            result.pages = document.pageCount
            for i in 0..<document.pageCount {
                try Task.checkCancellation()
                let value = FolderSearchService.indexedPage(document.page(at: i)!, index: i)
                if !value.text.isEmpty { result.textPages += 1 }; add(value, category: "PDF 当前正文")
            }
            if includeAnnotations {
                for note in ReadingServices.notes(document) where !note.note.isEmpty {
                    let value = FolderSearchPage(index: note.page, text: note.note, label: note.label, glyphs: nil, sourceRect: document.page(at: note.page)?.annotations[note.index].bounds)
                    add(value, category: "当前批注")
                }
            }
        } else {
            let content = card.map { $0.text + "\n" + $0.comment } ?? text ?? ""
            result.pages = 1; result.textPages = content.isEmpty ? 0 : 1
            add(FolderSearchPage(index: card?.source?.page ?? 0, text: content, label: nil, glyphs: nil), category: card == nil ? "文本当前编辑" : "工作区摘录")
        }
        return result
    }
}

extension WorkspaceStore {
    func searchSnapshots() throws -> [SearchSnapshot] {
        var values: [SearchSnapshot] = []
        for tab in tabs {
            if let note = tab.note { values.append(SearchSnapshot(id: note.id, title: note.title, path: note.fileURL, text: note.text)) }
            else if let workspace = tab.workspace, workspace.count > 0 {
                guard !workspace.busy else { throw FolioError(message: "请先完成当前文档任务，或取消搜索当前编辑内容") }
                values.append(SearchSnapshot(id: workspace.id, title: workspace.title, path: workspace.projectURL ?? workspace.sourceURL, revision: workspace.revision, pdf: try workspace.pdfData()))
            }
        }
        values += board.cards.map { SearchSnapshot(id: $0.id, title: $0.source?.fileName ?? "自由笔记", path: $0.source.map { URL(fileURLWithPath: $0.path) }, card: $0) }
        return values
    }
    @discardableResult func openLiveSearch(_ hit: FolderSearchHit) throws -> Bool {
        if let cardID = hit.cardID {
            guard let card = board.card(cardID), SearchSnapshot.cardDigest(card) == hit.fingerprint else { throw FolioError(message: "摘录已变化，请重新搜索") }
            UserDefaults.standard.set(true, forKey: LayoutKeys.board)
            if activeWorkspace == nil { let workspace = tabs.compactMap(\.workspace).first ?? addWorkspace(); select(workspace.id) }
            board.focus(cardID); return true
        }
        guard let id = hit.tabID else { return false }
        guard let tab = tabs.first(where: { $0.id == id }) else { throw FolioError(message: "来源标签页已关闭，请重新搜索") }
        if let note = tab.note {
            guard OCRPageCache.digest(Data(note.text.utf8)) == hit.fingerprint else { throw FolioError(message: "笔记已变化，请重新搜索") }
            select(id); note.revealSearch(hit.hit.range)
        } else if let workspace = tab.workspace {
            guard !workspace.busy, workspace.revision == hit.revision else { throw FolioError(message: "文档已变化，请重新搜索") }
            select(id)
            if let page = workspace.document.page(at: hit.hit.page) {
                let rects = hit.sourceRect.map { [$0] } ?? hit.hit.strips?.map { OrderedText.pageRect(forFraction: $0, cropBox: page.bounds(for: .cropBox), rotation: page.rotation) } ?? page.selection(for: hit.hit.range)?.selectionsByLine().map { $0.bounds(for: page) } ?? []
                workspace.go(to: ViewPosition(selection: hit.hit.page, x: nil, y: nil, scale: nil), highlighting: rects)
            }
        }
        return true
    }
    func liveExcerpt(_ hit: FolderSearchHit) throws -> (String, SourceRef) {
        if let cardID = hit.cardID {
            guard let card = board.card(cardID), SearchSnapshot.cardDigest(card) == hit.fingerprint else { throw FolioError(message: "摘录已变化，请重新搜索") }
            return (hit.hit.snippet, card.source ?? SourceRef(path: "", fileName: "自由笔记", page: 0))
        }
        guard let tab = tabs.first(where: { $0.id == hit.tabID }) else { throw FolioError(message: "来源标签页已关闭") }
        if let note = tab.note {
            guard OCRPageCache.digest(Data(note.text.utf8)) == hit.fingerprint else { throw FolioError(message: "笔记已变化，请重新搜索") }
            return (hit.hit.snippet, SourceRef(path: note.fileURL?.path ?? "", fileName: note.title, page: 0, anchor: hit.query))
        }
        guard let workspace = tab.workspace, workspace.revision == hit.revision, !workspace.busy else { throw FolioError(message: "文档已变化，请重新搜索") }
        return (hit.hit.snippet, SourceRef(path: (workspace.projectURL ?? workspace.sourceURL)?.path ?? "", fileName: workspace.title, page: hit.hit.page, rects: hit.sourceRect.map { [$0] } ?? [], anchor: hit.sourceRect == nil ? hit.query : nil))
    }
}

extension MarkdownNote {
    func revealSearch(_ range: NSRange) {
        pendingSearchRange = range
        Task { @MainActor [weak self] in
            for _ in 0..<12 {
                guard let self else { return }
                if let view = self.textView, view.window != nil {
                    let selected = Self.clamp(range, to: (view.string as NSString).length)
                    view.setSelectedRange(selected); view.scrollRangeToVisible(selected); view.showFindIndicator(for: selected); view.window?.makeFirstResponder(view); pendingSearchRange = nil; return
                }
                try? await Task.sleep(nanoseconds: 100_000_000)
            }
        }
    }
}
