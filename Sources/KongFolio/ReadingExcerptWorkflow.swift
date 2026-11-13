import Foundation

/// A section of one excerpt. Indices point to the record's canonical citations, including after page or file changes.
struct ReadingExcerptSegment: Codable, Equatable, Identifiable {
    var id = UUID()
    var text: String
    var originalText: String? = nil
    var citationIndices: [Int]
    var captured: Date

    func sources(in record: ReadingRecord) -> [ReadingCitation] {
        citationIndices.compactMap { record.citations.indices.contains($0) ? record.citations[$0] : nil }
    }

    private static func normalized(_ text: String) -> String {
        text.precomposedStringWithCompatibilityMapping.split(whereSeparator:\.isWhitespace).joined(separator:" ")
    }

    func duplicates(_ quote: String, citations: [ReadingCitation], in record: ReadingRecord) -> Bool {
        let prior = sources(in:record)
        guard !prior.isEmpty, prior.count == citations.count,
              zip(prior,citations).allSatisfy({ Self.sameLocation($0,$1) }) else { return false }
        return Self.normalized(originalText ?? text) == Self.normalized(quote)
    }

    private static func sameLocation(_ first: ReadingCitation, _ second: ReadingCitation) -> Bool {
        let a = first.source, b = second.source
        let sameID = first.tracking.map { $0.documentID == second.tracking?.documentID } ?? false
        let samePath = !a.path.isEmpty && ReadingBookIdentity.key(a.path) == ReadingBookIdentity.key(b.path)
        guard a.invalidPage053 != true,b.invalidPage053 != true,(sameID || samePath),a.page == b.page else { return false }
        if a.rects.isEmpty || b.rects.isEmpty { return true }
        guard a.rects.count == b.rects.count else { return false }
        return zip(a.rects,b.rects).allSatisfy { left,right in
            abs(left.minX-right.minX) <= 2 && abs(left.minY-right.minY) <= 2 &&
                abs(left.width-right.width) <= 2 && abs(left.height-right.height) <= 2
        }
    }
}

extension ReadingRecord {
    var textExcerptSegments: [ReadingExcerptSegment] {
        if let excerptSegments { return excerptSegments }
        guard kind == .excerpt,!quote.isEmpty else { return [] }
        return [ReadingExcerptSegment(id:id,text:quote,originalText:originalQuote,
                                      citationIndices:Array(citations.indices),captured:created)]
    }

    mutating func appendExcerpt(_ excerpt: ReadingRecord) {
        var segments = textExcerptSegments
        let start = citations.count
        citations.append(contentsOf:excerpt.citations)
        segments.append(ReadingExcerptSegment(text:excerpt.quote,citationIndices:Array(start..<citations.count),
                                              captured:excerpt.created))
        excerptSegments = segments
        quote = segments.map(\.text).joined(separator:"\n\n")
    }

    mutating func reviseExcerptSegment(_ id: UUID, text: String) {
        guard var segments = excerptSegments, let index = segments.firstIndex(where:{$0.id == id}),
              segments[index].text != text else { return }
        if segments[index].originalText == nil { segments[index].originalText = segments[index].text }
        segments[index].text = text
        excerptSegments = segments
        quote = segments.map(\.text).joined(separator:"\n\n")
    }
}

struct ReadingExcerptFeedback: Identifiable {
    let id = UUID()
    let recordID: UUID
    let message: String
    var opensEditor = false
}

struct ReadingExcerptUndo {
    let previous: ReadingRecord?
    let saved: ReadingRecord
    let previousLastNotes: [String:UUID]
    let previousLastExcerpt: UUID?
}

extension WorkspaceStore {
    var lastTextExcerpt: ReadingRecord? {
        if let record = journal.record(lastTextExcerptID),record.kind == .excerpt,
           record.removed == nil,!record.quote.isEmpty { return record }
        return journal.state.records.filter { $0.kind == .excerpt && $0.removed == nil && !$0.quote.isEmpty }
            .max { $0.created < $1.created }
    }

    func existingReadingExcerpt(_ capture:ReadingRecord) -> ReadingRecord? {
        guard !capture.quote.isEmpty,!capture.citations.isEmpty else { return nil }
        return journal.state.records.first { existing in
            existing.kind == .excerpt && existing.removed == nil &&
                existing.textExcerptSegments.contains {
                    $0.duplicates(capture.quote,citations:capture.citations,in:existing)
                }
        }
    }

    @discardableResult
    func saveReadingExcerpt(_ record: ReadingRecord, append: Bool = false) -> Bool {
        guard !journal.unreadable,record.kind == .excerpt,!record.quote.isEmpty else { return false }
        if let duplicate = existingReadingExcerpt(record) {
            revealCapturedExcerpt(duplicate,message:"已摘录过 · "+excerptLocation(record))
            return true
        }
        let previousLastExcerpt = lastTextExcerpt?.id
        let previous = append ? lastTextExcerpt : nil
        if append && previous == nil { return false }
        let pathKeys = Set((previous?.citations ?? []).map(\.source.path)+record.citations.map(\.source.path))
        let previousLastNotes = journal.state.lastNotes.filter { pathKeys.contains($0.key) }
        let saved: ReadingRecord
        if let previous {
            journal.editRecord(previous.id) { $0.appendExcerpt(record) }
            guard let current = journal.record(previous.id) else { return false }
            saved = current
        } else {
            journal.add(record)
            saved = record
        }
        lastTextExcerptID = saved.id
        readingExcerptUndo = ReadingExcerptUndo(previous:previous,saved:saved,previousLastNotes:previousLastNotes,
                                                 previousLastExcerpt:previousLastExcerpt)
        revealCapturedExcerpt(saved,message:(append ? "已追加 · " : "已保存摘录 · ")+excerptLocation(record))
        return true
    }

    func undoCapturedExcerpt(_ id: UUID) -> Bool {
        guard !journal.unreadable, let action = readingExcerptUndo, action.saved.id == id,
              journal.record(id) == action.saved else { return false }
        journal.change { state in
            guard let index = state.records.firstIndex(where:{$0.id == id}) else { return }
            if let previous = action.previous { state.records[index] = previous }
            else { state.records.remove(at:index) }
            for path in Set(action.saved.citations.map(\.source.path)) where state.lastNotes[path] == id {
                state.lastNotes[path] = action.previousLastNotes[path]
            }
        }
        readingExcerptUndo = nil
        commandWorkspace?.status = action.previous == nil ? "已撤销摘录" : "已撤销追加"
        lastTextExcerptID = action.previousLastExcerpt
        if action.previous == nil {
            readingRecordSelection.remove(id)
            if readingRecordID == id { readingRecordID = nil }
            if pinnedReadingID == id { pinnedReadingID = nil }
            readingExcerptFeedback = nil
        } else {
            readingExcerptFeedback = ReadingExcerptFeedback(recordID:id,message:"已撤销追加")
        }
        return true
    }

    func revealCapturedExcerpt(_ record: ReadingRecord, message: String, opensEditor:Bool = false) {
        rememberRightPanelNote()
        if let pinned = journal.record(pinnedReadingID), pinned.kind != .note { pinnedReadingID = nil }
        readingRecordID = record.id
        openReadingDesk(.excerpts)
        readingExcerptFeedback = ReadingExcerptFeedback(recordID:record.id,message:message,opensEditor:opensEditor)
    }

    private func excerptLocation(_ record: ReadingRecord) -> String {
        guard let first = record.citations.first else { return "阅读资料库" }
        let last = record.citations.last?.source.page ?? first.source.page
        if last != first.source.page { return "PDF 第 \(first.source.page+1)–\(last+1) 页" }
        return first.source.pageDescription
    }
}

extension Workspace {
    func appendSelectionToLastExcerpt() {
        guard let store, let selection = pdfView?.currentSelection, let record = readingExcerpt(from:selection) else {
            status = "请先在 PDF 中选中文字"
            return
        }
        if store.saveReadingExcerpt(record,append:true) { status = store.readingExcerptFeedback?.message ?? "已追加摘录" }
        else { status = "没有可追加的文字摘录" }
    }
}
