import AppKit
import UniformTypeIdentifiers

struct TextImageReference { var range: NSRange; var reference: String }
enum TextAssets {
    static func references(_ text: String, format: TextDocumentFormat) -> [TextImageReference] {
        let pattern: String
        switch format {
        case .plain: return []
        case .markdown: pattern = #"!\[[^\]]*\]\((<[^>]+>|[^\s)]+)(?:\s+\"[^\"]*\")?\)"#
        case .html: pattern = #"(?is)<img\b[^>]*\bsrc\s*=\s*(?:"([^"]*)"|'([^']*)'|([^\s>]+))[^>]*>"#
        }
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return [] }
        return regex.matches(in: text, range: NSRange(location: 0, length: (text as NSString).length)).compactMap { match in
            guard let group = (1..<match.numberOfRanges).first(where: { match.range(at: $0).location != NSNotFound }) else { return nil }
            var range = match.range(at: group)
            var value = (text as NSString).substring(with: range)
            if format == .markdown, value.hasPrefix("<"), value.hasSuffix(">") { range.location += 1; range.length -= 2; value = String(value.dropFirst().dropLast()) }
            return TextImageReference(range: range, reference: format == .html ? HTMLRichParser.decode(value) : value)
        }
    }
    static func saving(_ text: String, format: TextDocumentFormat, oldBase: URL?, destination: URL) throws -> String {
        let references = references(text, format: format)
        let result = NSMutableString(string: text)
        let folder = destination.deletingLastPathComponent().appendingPathComponent(destination.deletingPathExtension().lastPathComponent + "-assets", isDirectory: true)
        var copied: [String: String] = [:]
        for image in references.reversed() {
            // External web images remain external references; the offline preview clearly reports unsupported sources.
            guard image.reference.hasPrefix("data:image/") || TextMedia.resolve(image.reference, baseURL: oldBase) != nil else { continue }
            let relative: String
            if let existing = copied[image.reference] { relative = existing }
            else {
                let bytes = try TextMedia.read(image.reference, baseURL: oldBase)
                try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
                let filename = "image-" + SignaturePersistence.digest(bytes).prefix(16) + ".png"
                let file = folder.appendingPathComponent(filename)
                if !FileManager.default.fileExists(atPath: file.path) { try bytes.write(to: file, options: .atomic) }
                relative = (folder.lastPathComponent + "/" + filename).addingPercentEncoding(withAllowedCharacters: .urlPathAllowed.subtracting(CharacterSet(charactersIn: "()[]#?\"'"))) ?? filename
                copied[image.reference] = relative
            }
            result.replaceCharacters(in: image.range, with: relative)
        }
        return result as String
    }
}

extension MarkdownNote {
    func insertSource(_ source: String) {
        guard let view = textView else { text += (text.isEmpty ? "" : "\n") + source; return }
        let range = Self.clamp(view.selectedRange(), to: (view.string as NSString).length)
        apply(TextEdit(range: range, replacement: source, selection: NSRange(location: range.location + (source as NSString).length, length: 0)))
    }
    func insertTable() {
        guard format != .plain else { return }
        insertSource(format == .html ? "\n<table><tr><th>标题一</th><th>标题二</th></tr><tr><td>内容</td><td>内容</td></tr></table>\n" : "\n| 标题一 | 标题二 |\n| --- | --- |\n| 内容 | 内容 |\n")
    }
    func chooseImage() {
        let panel = NSOpenPanel(); panel.allowedContentTypes = [.image]; panel.allowsMultipleSelection = true
        guard panel.runModal() == .OK else { return }
        for url in panel.urls { insertImage(url) }
    }
    func insertImage(_ url: URL) {
        do { try insertImageData(TextMedia.read(url.absoluteString, baseURL: nil)) }
        catch { self.error = error.localizedDescription }
    }
    func insertImageData(_ data: Data) throws {
        guard format != .plain else { throw FolioError(message: "图片需要使用 Markdown 或 HTML 文件") }
        let folder = storage.appendingPathComponent("NoteAssets", isDirectory: true).appendingPathComponent(id.uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let file = folder.appendingPathComponent(UUID().uuidString + ".png")
        try data.write(to: file, options: .atomic)
        let reference = file.absoluteString
        insertSource(format == .html ? "\n<img src=\"\(reference)\" alt=\"图片\">\n" : "\n![图片](\(reference))\n")
    }
    @discardableResult func pasteImage() -> Bool {
        guard format != .plain, let image = SignatureImage.fromClipboard(), let data = SignatureImage.pngData(image) else { return false }
        do { try insertImageData(data) } catch { self.error = error.localizedDescription }
        return true
    }
}

final class NoteTextView: NSTextView {
    weak var note: MarkdownNote?
    override func paste(_ sender: Any?) {
        if NSPasteboard.general.availableType(from: [.png, .tiff]) != nil, note?.pasteImage() == true { return }
        super.paste(sender)
    }
    override func draggingEntered(_ sender: NSDraggingInfo) -> NSDragOperation {
        if note?.format != .plain, imageFiles(sender).count > 0 { return .copy }
        return super.draggingEntered(sender)
    }
    override func performDragOperation(_ sender: NSDraggingInfo) -> Bool {
        let files = imageFiles(sender)
        if note?.format != .plain, !files.isEmpty { files.forEach { note?.insertImage($0) }; return true }
        return super.performDragOperation(sender)
    }
    private func imageFiles(_ sender: NSDraggingInfo) -> [URL] {
        (sender.draggingPasteboard.readObjects(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) as? [URL] ?? []).filter { (try? $0.resourceValues(forKeys: [.contentTypeKey]).contentType?.conforms(to: .image)) == true }
    }
}
