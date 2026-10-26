import Foundation
import PDFKit

/// A local link keeps the full page/rectangle reference when notes are copied outside the app.
enum SourceLink {
    static func url(_ source: SourceRef) -> URL? {
        guard !source.path.isEmpty, let data = try? JSONEncoder().encode(source) else { return nil }
        var value = URLComponents(); value.scheme = "kongfolio"; value.host = "source"
        value.queryItems = [URLQueryItem(name: "ref", value: data.base64EncodedString())]
        return value.url
    }
    static func source(_ url: URL) -> SourceRef? {
        guard url.scheme == "kongfolio", url.host == "source", let components = URLComponents(url: url, resolvingAgainstBaseURL: false),
              let encoded = components.queryItems?.first(where: { $0.name == "ref" })?.value, encoded.count < 200000,
              let data = Data(base64Encoded: encoded), let source = try? JSONDecoder().decode(SourceRef.self, from: data),
              source.path.hasPrefix("/"), source.page >= 0, source.rects.allSatisfy({ $0.minX.isFinite && $0.minY.isFinite && $0.width.isFinite && $0.height.isFinite }) else { return nil }
        return source
    }
}

enum ExcerptNotebook {
    enum Grouping: String, CaseIterable, Identifiable { case file = "按文件", chapter = "按章节"; var id: String { rawValue } }
    static func render(_ cards: [BoardCard], title: String, grouping: Grouping, outlines: [String: [OutlineEntry]] = [:]) -> String {
        let ordered = cards.sorted {
            let a = $0.source, b = $1.source
            if a?.path != b?.path { return (a?.path ?? "~") < (b?.path ?? "~") }
            if a?.page != b?.page { return (a?.page ?? 0) < (b?.page ?? 0) }
            return $0.y < $1.y
        }
        var lines = ["# " + title.replacingOccurrences(of: "\n", with: " "), ""]
        var previousFile: String?, previousChapter: String?
        for card in ordered {
            let file = card.source?.path ?? ""
            if previousFile != file {
                lines += ["## " + (card.source?.fileName ?? "自由笔记"), ""]
                if !file.isEmpty { lines += ["来源路径：" + file, ""] }
                previousFile = file; previousChapter = nil
            }
            if grouping == .chapter, let source = card.source {
                let chapter = (outlines[file] ?? []).filter { $0.page <= source.page }.sorted { $0.page < $1.page }.last?.label ?? "未分章"
                if previousChapter != chapter { lines += ["### " + chapter, ""]; previousChapter = chapter }
            }
            if card.kind == .note { lines += [card.text, ""] }
            else if card.kind == .image { lines += ["> （图片摘录：请从出处查看原图）", ""] }
            else { lines += card.text.components(separatedBy: "\n").map { "> " + $0 }; lines.append("") }
            if let source = card.source {
                lines += ["出处：\(source.fileName)，\(source.pageDescription)"]
                if let link = SourceLink.url(source) { lines += ["[返回原文](\(link.absoluteString))"] }
                lines.append("")
            }
            if !card.comment.isEmpty { lines += ["**我的评论**", "", card.comment, ""] }
        }
        return lines.joined(separator: "\n")
    }
}
