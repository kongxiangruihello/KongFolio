import Foundation
import PDFKit

struct WordPreparedParagraph: Equatable { var text: String; var heading: Int = 0 }
struct WordPreparedPage { var index: Int; var label: String?; var paragraphs: [WordPreparedParagraph]; var blocks: [WordPreparedBlock]? = nil }
struct WordMarginCandidate: Identifiable { var id: String; var example: String; var pages: Int }

enum WordCleanup {
    static func lines(_ text: String) -> [String] {
        TextImport.normalized(text).components(separatedBy: "\n").map { $0.trimmingCharacters(in: .whitespaces) }
    }
    static func key(_ line: String, top: Bool) -> String {
        let normalized = line.replacingOccurrences(of: #"[0-9０-９]+"#, with: "#", options: .regularExpression)
        return (top ? "上：" : "下：") + normalized
    }
    /// Only the outermost lines count; repeated sentences in the body are never treated as running headers.
    static func candidates(_ texts: [String]) -> [WordMarginCandidate] {
        guard texts.count >= 3 else { return [] }
        var counts: [String: Int] = [:], examples: [String: String] = [:]
        for text in texts {
            let content = lines(text).filter { !$0.isEmpty }
            guard content.count >= 5 else { continue }
            var seen = Set<String>()
            for (top, values) in [(true, Array(content.prefix(1))), (false, Array(content.suffix(1)))] {
                for line in values where line.count <= 80 {
                    let id = key(line, top: top); seen.insert(id); examples[id] = line
                }
            }
            for id in seen { counts[id, default: 0] += 1 }
        }
        let threshold = max(3, Int(ceil(Double(texts.count) * 0.6)))
        return counts.keys.sorted().compactMap { id in
            guard counts[id, default: 0] >= threshold else { return nil }
            return WordMarginCandidate(id: id, example: examples[id] ?? id, pages: counts[id]!)
        }
    }
    static func heading(_ text: String) -> Int {
        guard text.count <= 70 else { return 0 }
        if text.range(of: #"^第[〇零一二三四五六七八九十百千两壹贰叁0-9０-９]+[卷编部篇章](?:\s|[^。！？；]{0,55}$)"#, options: .regularExpression) != nil { return 1 }
        if text.range(of: #"^(?:第[一二三四五六七八九十百0-9]+节|[一二三四五六七八九十]+、|[（(][一二三四五六七八九十0-9]+[）)])[^。！？；]{0,55}$"#, options: .regularExpression) != nil { return 2 }
        return 0
    }
    static func raw(_ page: PDFPage, regions: [RecognizedLine]?) -> String {
        if let regions, !OrderedText.isVertical(regions), !regions.isEmpty { return regions.map(\.text).joined(separator: "\n") }
        return page.string ?? ""
    }
    static func editedParagraphs(_ text: String, headings: Bool) -> [WordPreparedParagraph] {
        var result: [WordPreparedParagraph] = [], pending: [String] = []
        func flush() {
            if !pending.isEmpty { result.append(WordPreparedParagraph(text: pending.joined(separator: "\n"))); pending = [] }
        }
        for line in lines(text) {
            if line.isEmpty { flush() }
            else {
                let level = headings ? heading(line) : 0
                if level > 0 { flush(); result.append(WordPreparedParagraph(text: line, heading: level)) }
                else { pending.append(line) }
            }
        }
        flush(); return result
    }
    static func prepare(index: Int, label: String?, text: String, regions: [RecognizedLine]?, options: WordExportOptions, margins: Set<String>) -> WordPreparedPage {
        if let edited = options.editedText?[index] {
            return WordPreparedPage(index: index, label: label, paragraphs: editedParagraphs(edited, headings: options.recognizeHeadings != false))
        }
        if let regions, OrderedText.isVertical(regions) {
            let paragraphs = OrderedText.paragraphs(regions: regions, pageText: text, mergeLines: options.mergeLines, keepColumns: options.keepColumns)
            return WordPreparedPage(index: index, label: label, paragraphs: paragraphs.map { WordPreparedParagraph(text: ReplacementRules.apply(options.replacements, to: $0)) })
        }
        var source = lines(text)
        let positions = source.indices.filter { !source[$0].isEmpty }
        if options.removeRunningMargins == true, positions.count >= 5 {
            if let first = positions.first, margins.contains(key(source[first], top: true)) { source[first] = "" }
            if let last = positions.last, margins.contains(key(source[last], top: false)) { source[last] = "" }
        }
        // Keep title boundaries before merging the body. Blank lines remain paragraph boundaries.
        var paragraphs: [WordPreparedParagraph] = [], pending: [String] = []
        func flush() {
            paragraphs += WordExport.paragraphs(from: pending.joined(separator: "\n"), merge: options.mergeLines).map { WordPreparedParagraph(text: $0) }
            pending = []
        }
        for line in source {
            let level = options.recognizeHeadings == false ? 0 : heading(line)
            if level > 0 { flush(); paragraphs.append(WordPreparedParagraph(text: line, heading: level)) }
            else { pending.append(line) }
        }
        flush()
        paragraphs = paragraphs.map { WordPreparedParagraph(text: ReplacementRules.apply(options.replacements, to: ReadingServices.repairIdeographs($0.text)), heading: $0.heading) }
        return WordPreparedPage(index: index, label: label, paragraphs: paragraphs)
    }
    static func inspect(_ document: PDFDocument, pages: [Int], options: WordExportOptions, regions: [Int: [RecognizedLine]], sourceDigest: String? = nil) throws -> (pages: [WordPreparedPage], candidates: [WordMarginCandidate]) {
        let tables = options.includeTables == false || options.content == .imagesOnly ? [] : (options.tables ?? [])
        try WordTables.validate(tables, document: document, pages: pages, options: options, sourceDigest: sourceDigest)
        let texts = try pages.map { index -> String in
            try Task.checkCancellation(); return raw(try document.page(at: index).unwrap("页面缺失"), regions: regions[index])
        }
        let candidates = candidates(texts)
        let margins = Set(options.removedMarginKeys ?? candidates.map(\.id))
        let prepared = try zip(pages, texts).map { index, text -> WordPreparedPage in
            var value = prepare(index: index, label: ReadingServices.pageLabel(document.page(at: index)!, index: index), text: text, regions: regions[index], options: options, margins: margins)
            if let blocks = try WordTables.blocks(page: document.page(at: index)!, index: index, tables: tables, options: options, margins: margins) {
                value.blocks = blocks; value.paragraphs = blocks.compactMap { if case .paragraph(let p) = $0 { return p }; return nil }
            }
            return value
        }
        return (prepared, candidates)
    }
}
