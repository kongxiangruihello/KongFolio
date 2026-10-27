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
    static func rebasedText(_ text: String, baseURL: URL?) throws -> String {
        let regex = try NSRegularExpression(pattern: #"kongfolio://source\?ref=[A-Za-z0-9%+/=]+"#)
        let result = NSMutableString(string: text)
        for match in regex.matches(in: text, range: NSRange(location: 0, length: (text as NSString).length)).reversed() {
            guard let url = URL(string: (text as NSString).substring(with: match.range)), let original = source(url), original.relativePath != nil else { continue }
            var resolved = try resolved(original, baseURL: baseURL); resolved.relativePath = nil
            if let replacement = Self.url(resolved) { result.replaceCharacters(in: match.range, with: replacement.absoluteString) }
        }
        return result as String
    }
    /// Carry only the originals explicitly referenced by a portable note, never an entire source folder.
    static func saving(_ text: String, oldBase: URL?, destination: URL) throws -> String {
        let regex = try NSRegularExpression(pattern: #"kongfolio://source\?ref=[A-Za-z0-9%+/=]+"#)
        let result = NSMutableString(string: text), fm = FileManager.default
        let newBase = destination.deletingLastPathComponent().standardizedFileURL.resolvingSymlinksInPath()
        let sameBase = oldBase?.standardizedFileURL.resolvingSymlinksInPath() == newBase
        var carried: [String: SourceRef] = [:]
        for match in regex.matches(in: text, range: NSRange(location: 0, length: (text as NSString).length)).reversed() {
            guard let link = URL(string: (text as NSString).substring(with: match.range)), var source = Self.source(link), source.relativePath != nil else { continue }
            let current = try resolved(source, baseURL: oldBase)
            if sameBase { source.path = current.path }
            else if let saved = carried[current.path] { source.path = saved.path; source.relativePath = saved.relativePath; source.fingerprint = saved.fingerprint }
            else {
                let bytes = try Data(contentsOf: URL(fileURLWithPath: current.path)), digest = OCRPageCache.digest(bytes)
                let folder = newBase.appendingPathComponent(destination.deletingPathExtension().lastPathComponent + "-sources", isDirectory: true)
                try fm.createDirectory(at: folder, withIntermediateDirectories: true)
                let ext = URL(fileURLWithPath: current.path).pathExtension
                let name = digest + (ext.isEmpty ? "" : "." + ext)
                let target = folder.appendingPathComponent(name)
                if fm.fileExists(atPath: target.path) {
                    guard OCRPageCache.digest(try Data(contentsOf: target)) == digest else { throw FolioError(message: "目标原件副本内容不符，请选择其他保存位置") }
                } else { try bytes.write(to: target, options: .atomic) }
                source.path = target.path; source.relativePath = folder.lastPathComponent + "/" + name; source.fingerprint = digest
                carried[current.path] = source
            }
            if let replacement = Self.url(source) { result.replaceCharacters(in: match.range, with: replacement.absoluteString) }
        }
        return result as String
    }
    static func resolved(_ source: SourceRef, baseURL: URL?) throws -> SourceRef {
        guard let relative = source.relativePath else { return source }
        guard let baseURL, !relative.hasPrefix("/"), !relative.components(separatedBy: "/").contains("..") else { throw FolioError(message: "请先打开资料包中的笔记，再返回原文") }
        let base = baseURL.standardizedFileURL.resolvingSymlinksInPath()
        let url = base.appendingPathComponent(relative).standardizedFileURL.resolvingSymlinksInPath()
        guard url.path.hasPrefix(base.path + "/"), FileManager.default.fileExists(atPath: url.path) else { throw FolioError(message: "资料包中的原件缺失：" + relative) }
        if let fingerprint = source.fingerprint, OCRPageCache.digest(try Data(contentsOf: url)) != fingerprint { throw FolioError(message: "资料包原件已变化，请核对来源") }
        var result = source; result.path = url.path; return result
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
            else if card.kind == .image {
                if let data = card.imageData { lines += ["![图片摘录](data:image/png;base64," + data.base64EncodedString() + ")", ""] }
                else { lines += ["> （图片摘录缺少图像，请从出处查看）", ""] }
            }
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
